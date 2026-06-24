// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS) || os(macOS)
    import Foundation
    import OnnxRuntimeBindings  // SPM module of the "onnxruntime" product
    import os.log

    /// Kokoro narration via **ONNX Runtime (CPU)** — the default on-device engine
    /// (it replaced the fixed-shape CoreML pipeline).
    ///
    /// Why this exists: the CoreML path AOT-compiles its model graphs on-device on
    /// first run (~20 min on an A14 — the LSTM duration predictor is O(n²) to
    /// compile). ONNX Runtime *interprets* the graph: ~1 s session-load, no
    /// Espresso compile. ORT's CoreML EP can't run Kokoro's dynamic shapes, so this
    /// runs on the **CPU EP by construction** — which also means it never touches
    /// the ANE, so it can't hit the A14 BNNS vocoder trap either.
    ///
    /// Reuses Echo's existing front-half verbatim: MisakiSwift G2P → KokoroPhonemeVocab
    /// (BOS/EOS-wrapped ids) → KokoroVoicePack (256-dim af_heart refS). Only the
    /// runtime changes. The single ONNX graph (`model_fp16.onnx`, 163 MB) contains
    /// duration, F0/N, decoder-pre, hn-NSF, and the generator internally.
    ///
    /// Model I/O contract (verified against onnx-community/Kokoro-82M-v1.0-ONNX):
    ///   inputs : input_ids INT64 [1, n] · style FLOAT [1, 256] · speed FLOAT [1]
    ///   output : waveform  FLOAT [1, num_samples]  (24 kHz mono)
    ///
    /// Logs session-load time and per-synthesis RTF (used to clear the A14 gate on
    /// device: ~0.7 s load, RTF ≈ 0.5). Compiles on iOS + macOS — both link ORT and
    /// run the CPU EP; no UIKit/AppKit dependency.
    actor OnnxKokoroEngine: TTSEngine {
        private let logger = Logger(category: "OnnxKokoro")
        private var env: ORTEnv?
        private var session: ORTSession?
        private var initializationTask: Task<Void, Error>?
        private var progressFanOut: ProgressFanOut?
        private var didLogFirstSynthesis = false

        /// Immutable Kokoro front-half (G2P + vocab + per-voice style packs), loaded
        /// once and reused across every synthesize call instead of being rebuilt per
        /// sub-chunk (~6 MB lexicon parse + voice-blob read each). See KokoroFrontEnd.
        private let frontEnd = KokoroFrontEnd()

        /// Resolves the local model URL (downloading once if absent). Injected so a
        /// test can exercise the failure path of `prepare()` without a network or
        /// the 163 MB model; defaults to the real `ensureModel`.
        private let modelProvider: @Sendable (@Sendable (Double) -> Void) async throws -> URL

        /// Intra-op thread count for the CPU EP. The A14 has 2 performance cores;
        /// pinning intra-op parallelism to them is the throughput lever measured on
        /// device. Injectable so the on-device spike can compare 1/2/4.
        private let intraOpThreads: Int32

        /// Test seam: surface the configured thread count without exposing internals.
        var intraOpThreadsForTesting: Int32 { intraOpThreads }

        init(intraOpThreads: Int32 = 2) {
            self.modelProvider = { progress in try await Self.ensureModel(progress: progress) }
            self.intraOpThreads = intraOpThreads
        }

        /// Test seam: inject a custom model provider (e.g. one that throws) to drive
        /// the no-cache-on-failure retry path.
        init(
            modelProvider: @escaping @Sendable (@Sendable (Double) -> Void) async throws -> URL,
            intraOpThreads: Int32 = 2
        ) {
            self.modelProvider = modelProvider
            self.intraOpThreads = intraOpThreads
        }

        // MARK: - Model location

        /// renderVersion-keyed subdir (v6 = the ONNX engine) under the shared
        /// narration cache, parallel to the CoreML `kokoro-fixed-v5` set.
        private nonisolated static let modelSubdir = "Models/kokoro-onnx-v6"
        private nonisolated static let modelFileName = "model_fp16.onnx"
        /// Immutable commit pin for onnx-community/Kokoro-82M-v1.0-ONNX. Pinning a
        /// revision (not the moving `main` ref) means a future upstream re-upload can't
        /// silently change the model behind renderVersion 6. Validated at pin time:
        /// 163_234_740 B · sha256 ba4527a8…35c334a (onnx/model_fp16.onnx).
        private nonisolated static let modelRevision = "1939ad2a8e416c0acfeecc08a694d14ef25f2231"
        private nonisolated static let hfModelURL = URL(
            string:
                "https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX/resolve/\(modelRevision)/onnx/model_fp16.onnx"
        )!

        nonisolated static func modelDirectory() -> URL {
            NarrationCache.directory().appendingPathComponent(modelSubdir, isDirectory: true)
        }
        nonisolated static func modelURL() -> URL {
            modelDirectory().appendingPathComponent(modelFileName)
        }

        /// Exact LFS byte length of `model_fp16.onnx` at the pinned revision. A pinned,
        /// content-addressed download is either exactly this size or corrupt/truncated,
        /// so an exact-size match is a cheap, sufficient integrity check.
        nonisolated static let expectedModelBytes = 163_234_740

        /// Test seam: the immutable remote model URL, so a unit test can assert it is
        /// pinned to a commit revision rather than the moving `main` branch ref.
        nonisolated static var remoteModelURLForTesting: URL { hfModelURL }

        /// True iff a file exists at `url` whose byte length is exactly `expectedBytes`.
        /// A pinned, content-addressed download is either exactly this size or corrupt/
        /// truncated, so an exact-size match is a cheap, sufficient integrity check that
        /// also self-heals an interrupted prior download (wrong size ⇒ re-fetch). Cheap:
        /// a single stat, no hashing.
        nonisolated static func fileHasExpectedSize(at url: URL, expectedBytes: Int) -> Bool {
            guard
                let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
                let size = attrs[.size] as? Int
            else { return false }
            return size == expectedBytes
        }

        // MARK: - TTSEngine

        func prepare() async throws { try await prepare(progress: { _ in }) }

        func prepare(progress: @escaping @Sendable (NarrationPrepareProgress) -> Void) async throws
        {
            if session != nil {
                progress(.ready)
                return
            }
            if let task = initializationTask {
                progressFanOut?.add(progress)
                try await task.value
                progress(.ready)
                return
            }
            let fan = ProgressFanOut()
            fan.add(progress)
            progressFanOut = fan
            let task = Task<Void, Error> { [logger, modelProvider, intraOpThreads] in
                defer { fan.clear() }
                let modelURL = try await modelProvider { f in
                    fan.emit(.downloadingModels(fraction: f))
                }
                // No Espresso/AOT compile — session-create is the whole cost, and
                // it's seconds. Time it so the A14 spike has the load number.
                fan.emit(.compilingModels(done: 0, total: 1))
                let loadStart = Date()
                let env = try ORTEnv(loggingLevel: ORTLoggingLevel.warning)
                let options = try ORTSessionOptions()
                // Tuning (behavior-preserving): op fusion + pin intra-op parallelism to the
                // A14 performance cores. CPU EP only — no ANE (the A14 trap path).
                try options.setGraphOptimizationLevel(.all)
                try options.setIntraOpNumThreads(intraOpThreads)
                let session = try ORTSession(
                    env: env, modelPath: modelURL.path, sessionOptions: options)
                let loadMs = Int(Date().timeIntervalSince(loadStart) * 1000)
                logger.notice(
                    "ONNX session created in \(loadMs, privacy: .public) ms (no AOT compile), intraOp=\(intraOpThreads, privacy: .public)."
                )
                self.store(env: env, session: session)
                fan.emit(.compilingModels(done: 1, total: 1))
                fan.emit(.ready)
            }
            initializationTask = task
            do {
                try await task.value
            } catch {
                // §5.11: a failed initialization must not stay cached, or every
                // later prepare() re-awaits the same failure forever (a transient
                // network/disk error would brick narration until app relaunch).
                // Joiners only ever re-await this task — they never replace it — so
                // clearing here cannot drop a newer attempt.
                initializationTask = nil
                throw error
            }
        }

        /// Speeds tried, in order, when a fragment comes back silent — the
        /// prosody-neutral first recovery step. Leads with `1.0` (the real playback
        /// speed → no extra synthesis for the ~90% of chunks that aren't silent); the
        /// ±3% nudges are inaudible but change the duration predictor's output enough
        /// to (hopefully) dodge an input-specific all-zero before the guard resorts to
        /// splitting the text. Tunable; efficacy is a model property, confirmed on
        /// device. See `NarrationSilenceGuard.synthesizeWithSpeedNudge`.
        nonisolated static let silenceRecoverySpeeds: [Float] = [1.0, 1.03, 0.97]

        func synthesize(_ text: String, voice: VoiceID) async throws -> TTSChunk {
            try await prepare()
            guard session != nil else { throw NarrationError.engineUnavailable }

            // The ONNX model occasionally returns a full-length but all-zero
            // waveform (digital silence) for a non-empty input. Recover in order of
            // increasing prosody cost: a small speed nudge on the whole fragment
            // (one utterance, no seam) first, then — if every speed is still silent —
            // the guard's text perturb/split ladder. The speed nudge applies to each
            // fragment the guard tries, including split halves.
            let samples = try await NarrationSilenceGuard.synthesize(text) { piece in
                try await NarrationSilenceGuard.synthesizeWithSpeedNudge(
                    speeds: Self.silenceRecoverySpeeds
                ) { speed in
                    try await self.runModel(piece, voice: voice, speed: speed)
                }
            }
            let audioS = Double(samples.count) / 24_000
            return TTSChunk(samples: samples, sampleRate: 24_000, duration: audioS)
        }

        /// One encode + ONNX run for a single text fragment at a given `speed` → PCM
        /// samples (an empty array means "nothing to synthesize", e.g. an
        /// all-punctuation fragment). Wrapped by `NarrationSilenceGuard`, which
        /// speed-nudges / retries / re-splits when the model returns a silent
        /// (all-zero) waveform.
        private func runModel(_ text: String, voice: VoiceID, speed: Float) async throws -> [Float]
        {
            guard let session else { throw NarrationError.engineUnavailable }

            // Reuse Echo's verified front-half: G2P → vocab ids (BOS/EOS-wrapped)
            // → af_heart refS row (clamped by phoneme count). Cached on `frontEnd`
            // so the ~6 MB MisakiSwift lexicon + the voice blob load ONCE, not on
            // every text sub-chunk (which is what NarrationService feeds us).
            let (ids32, refS) = try frontEnd.encode(text: text, voice: voice)

            // Boundary-only ids ([BOS, EOS]) mean every phoneme was dropped — there
            // is nothing to say. Treat it as empty (a legit zero-length fragment the
            // guard won't retry) rather than feeding it to the model, which would
            // return unrecoverable digital silence.
            guard ids32.contains(where: { $0 != KokoroPhonemeVocab.boundaryTokenId }) else {
                return []
            }

            // Widen ids to Int64 for the ONNX `input_ids` tensor.
            let ids64 = ids32.map { Int64($0) }
            let speedInput: [Float] = [speed]

            let inputIds = try ORTValue(
                tensorData: Self.tensorData(ids64),
                elementType: .int64,
                shape: [NSNumber(value: 1), NSNumber(value: ids64.count)])
            let styleValue = try ORTValue(
                tensorData: Self.tensorData(refS),
                elementType: .float,
                shape: [NSNumber(value: 1), NSNumber(value: refS.count)])
            let speedValue = try ORTValue(
                tensorData: Self.tensorData(speedInput),
                elementType: .float,
                shape: [NSNumber(value: 1)])

            let runStart = Date()
            let outputs = try session.run(
                withInputs: ["input_ids": inputIds, "style": styleValue, "speed": speedValue],
                outputNames: ["waveform"],
                runOptions: nil)
            let computeS = Date().timeIntervalSince(runStart)

            guard let waveform = outputs["waveform"] else { throw NarrationError.engineUnavailable }
            let data = try waveform.tensorData()  // ObjC tensorDataWithError: → throwing tensorData()
            let samples = data.toFloatArray()
            let audioS = Double(samples.count) / 24_000

            // The make-or-break number: RTF (compute/audio; <1 = faster than realtime).
            let rtf = audioS > 0 ? computeS / audioS : 0
            let tag = didLogFirstSynthesis ? "synth" : "FIRST synth (cold)"
            didLogFirstSynthesis = true
            logger.notice(
                "\(tag, privacy: .public): \(ids32.count, privacy: .public) tokens → \(String(format: "%.2f", audioS), privacy: .public)s audio in \(String(format: "%.2f", computeS), privacy: .public)s compute (RTF \(String(format: "%.2f", rtf), privacy: .public))"
            )

            // The model sometimes returns a full-length all-zero waveform; flag it
            // so the guard's retry/re-split is visible and the rate is monitorable.
            if NarrationSilenceGuard.isEffectivelySilent(samples) {
                logger.warning(
                    "Silent (all-zero) waveform for \(ids32.count, privacy: .public) tokens — retrying/splitting."
                )
            }

            return samples
        }

        // MARK: - Private

        private func store(env: ORTEnv, session: ORTSession) {
            self.env = env
            self.session = session
        }

        /// Copies a numeric array's raw bytes into `NSMutableData` for an ORTValue
        /// tensor — via `withUnsafeBufferPointer` so there's no array-to-pointer
        /// lifetime ambiguity. `NSMutableData(bytes:length:)` copies the bytes.
        private nonisolated static func tensorData<T>(_ array: [T]) -> NSMutableData {
            array.withUnsafeBufferPointer { buf in
                NSMutableData(bytes: buf.baseAddress, length: buf.count * MemoryLayout<T>.stride)
            }
        }

        /// Returns the local model URL, downloading the single `.onnx` once if absent.
        /// An on-disk file (including a USB-sideloaded one) short-circuits the download
        /// only when its byte length matches the pinned model exactly — a truncated,
        /// partial, or stale file is discarded and re-fetched. A fresh download streams
        /// to a temp file with byte-level progress, and is size-validated before its
        /// path is handed to ORT (which would otherwise fail later with an opaque
        /// session-create error).
        private nonisolated static func ensureModel(progress: @Sendable (Double) -> Void) async throws -> URL {
            let dest = modelURL()
            let fm = FileManager.default
            if fm.fileExists(atPath: dest.path) {
                if fileHasExpectedSize(at: dest, expectedBytes: expectedModelBytes) {
                    progress(1.0)
                    return dest
                }
                try? fm.removeItem(at: dest)  // corrupt / partial / stale — re-fetch
            }
            try? fm.createDirectory(at: modelDirectory(), withIntermediateDirectories: true)
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForResource = 3_600
            let (byteStream, response) = try await URLSession(configuration: config).bytes(
                from: hfModelURL)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw NarrationError.modelDownloadFailed(name: modelFileName, underlying: nil)
            }

            // Stream the body to a temp file in 64 KB chunks — so the 163 MB model never
            // sits in memory — reporting progress against the known pinned size. The
            // `progress` closure is called inline (never stored), so this needs no
            // escaping closure; the per-byte loop overhead is hidden behind network I/O.
            let tempURL = modelDirectory().appendingPathComponent("\(modelFileName).download")
            try? fm.removeItem(at: tempURL)
            fm.createFile(atPath: tempURL.path, contents: nil)
            let handle = try FileHandle(forWritingTo: tempURL)
            let total = Double(expectedModelBytes)
            var received = 0
            var chunk = [UInt8]()
            chunk.reserveCapacity(1 << 16)
            do {
                for try await byte in byteStream {
                    chunk.append(byte)
                    if chunk.count == (1 << 16) {
                        try handle.write(contentsOf: Data(chunk))
                        received += chunk.count
                        chunk.removeAll(keepingCapacity: true)
                        progress(min(1.0, Double(received) / total))
                    }
                }
                if !chunk.isEmpty {
                    try handle.write(contentsOf: Data(chunk))
                    received += chunk.count
                }
                try handle.close()
            } catch {
                try? handle.close()
                try? fm.removeItem(at: tempURL)
                throw NarrationError.modelDownloadFailed(name: modelFileName, underlying: error)
            }

            guard fileHasExpectedSize(at: tempURL, expectedBytes: expectedModelBytes) else {
                try? fm.removeItem(at: tempURL)
                throw NarrationError.modelDownloadFailed(name: modelFileName, underlying: nil)
            }
            try? fm.removeItem(at: dest)  // clear any stale file before the atomic move
            try fm.moveItem(at: tempURL, to: dest)
            progress(1.0)
            return dest
        }
    }

    extension NSData {
        /// Reinterprets raw tensor bytes as a Float32 array (the ONNX `waveform`
        /// output is fp32 even though the model's weights are fp16).
        nonisolated fileprivate func toFloatArray() -> [Float] {
            let count = length / MemoryLayout<Float>.stride
            guard count > 0 else { return [] }
            var out = [Float](repeating: 0, count: count)
            // NSData lacks Data's closure `withUnsafeBytes`; copy from its raw
            // `bytes` pointer into the Float buffer directly.
            out.withUnsafeMutableBytes { dst in
                dst.copyMemory(from: UnsafeRawBufferPointer(start: bytes, count: dst.count))
            }
            return out
        }
    }
#endif
