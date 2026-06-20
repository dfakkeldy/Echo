// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS)
    import Foundation
    import OnnxRuntimeBindings  // SPM module of the "onnxruntime" product
    import os.log

    /// Spike engine: Kokoro narration via **ONNX Runtime (CPU)** instead of the
    /// fixed-shape CoreML pipeline.
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
    /// This is a make-or-break spike: it logs session-load time and per-synthesis
    /// RTF so the A14 throughput gate can be measured on a real device. iOS-only for
    /// now so the macOS build isn't gated on adding ORT to that target.
    actor OnnxKokoroEngine: TTSEngine {
        private let logger = Logger(category: "OnnxKokoro")
        private var env: ORTEnv?
        private var session: ORTSession?
        private var initializationTask: Task<Void, Error>?
        private var progressFanOut: ProgressFanOut?
        private var didLogFirstSynthesis = false

        init() {}

        // MARK: - Model location

        /// renderVersion-keyed subdir (v6 = the ONNX engine) under the shared
        /// narration cache, parallel to the CoreML `kokoro-fixed-v5` set.
        private static let modelSubdir = "Models/kokoro-onnx-v6"
        private static let modelFileName = "model_fp16.onnx"
        private static let hfModelURL = URL(
            string:
                "https://huggingface.co/onnx-community/Kokoro-82M-v1.0-ONNX/resolve/main/onnx/model_fp16.onnx"
        )!

        nonisolated static func modelDirectory() -> URL {
            NarrationCache.directory().appendingPathComponent(modelSubdir, isDirectory: true)
        }
        nonisolated static func modelURL() -> URL {
            modelDirectory().appendingPathComponent(modelFileName)
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
            let task = Task<Void, Error> { [logger] in
                defer { fan.clear() }
                let modelURL = try await Self.ensureModel { f in
                    fan.emit(.downloadingModels(fraction: f))
                }
                // No Espresso/AOT compile — session-create is the whole cost, and
                // it's seconds. Time it so the A14 spike has the load number.
                fan.emit(.compilingModels(done: 0, total: 1))
                let loadStart = Date()
                let env = try ORTEnv(loggingLevel: ORTLoggingLevel.warning)
                let options = try ORTSessionOptions()
                // CPU EP only (ORT's CoreML EP can't run Kokoro's dynamic shapes,
                // and routing to the ANE is the exact path that traps on A14).
                let session = try ORTSession(
                    env: env, modelPath: modelURL.path, sessionOptions: options)
                let loadMs = Int(Date().timeIntervalSince(loadStart) * 1000)
                logger.notice(
                    "ONNX session created in \(loadMs, privacy: .public) ms (no AOT compile).")
                await self.store(env: env, session: session)
                fan.emit(.compilingModels(done: 1, total: 1))
                fan.emit(.ready)
            }
            initializationTask = task
            try await task.value
        }

        func synthesize(_ text: String, voice: VoiceID) async throws -> TTSChunk {
            try await prepare()
            guard let session else { throw NarrationError.engineUnavailable }

            // Reuse Echo's verified front-half: G2P → vocab ids (BOS/EOS-wrapped)
            // → af_heart refS row (clamped by phoneme count).
            let g2p = KokoroG2P()
            let vocab = try KokoroPhonemeVocab()
            let pack = try KokoroVoicePack(named: voice.rawValue)
            let phonemes = g2p.phonemes(for: text)
            let ids32 = vocab.ids(forPhonemes: phonemes)  // [Int32], BOS/EOS = 0
            let refS = pack.refS(forPhonemeCount: phonemes.count)  // [Float], 256

            guard !ids32.isEmpty else {
                return TTSChunk(samples: [], sampleRate: 24_000, duration: 0)
            }

            // Widen ids to Int64 for the ONNX `input_ids` tensor.
            let ids64 = ids32.map { Int64($0) }
            let speed: [Float] = [1.0]

            let inputIds = try ORTValue(
                tensorData: Self.tensorData(ids64),
                elementType: .int64,
                shape: [NSNumber(value: 1), NSNumber(value: ids64.count)])
            let styleValue = try ORTValue(
                tensorData: Self.tensorData(refS),
                elementType: .float,
                shape: [NSNumber(value: 1), NSNumber(value: refS.count)])
            let speedValue = try ORTValue(
                tensorData: Self.tensorData(speed),
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

            return TTSChunk(samples: samples, sampleRate: 24_000, duration: audioS)
        }

        // MARK: - Private

        private func store(env: ORTEnv, session: ORTSession) {
            self.env = env
            self.session = session
        }

        /// Copies a numeric array's raw bytes into `NSMutableData` for an ORTValue
        /// tensor — via `withUnsafeBufferPointer` so there's no array-to-pointer
        /// lifetime ambiguity. `NSMutableData(bytes:length:)` copies the bytes.
        private static func tensorData<T>(_ array: [T]) -> NSMutableData {
            array.withUnsafeBufferPointer { buf in
                NSMutableData(bytes: buf.baseAddress, length: buf.count * MemoryLayout<T>.stride)
            }
        }

        /// Returns the local model URL, downloading the single `.onnx` once if
        /// absent. A USB-sideloaded model short-circuits the download (file exists).
        private static func ensureModel(progress: @Sendable (Double) -> Void) async throws -> URL {
            let dest = modelURL()
            let fm = FileManager.default
            if fm.fileExists(atPath: dest.path) {
                progress(1.0)
                return dest
            }
            try? fm.createDirectory(at: modelDirectory(), withIntermediateDirectories: true)
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForResource = 3_600
            let (tempURL, response) = try await URLSession(configuration: config).download(
                from: hfModelURL)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                try? fm.removeItem(at: tempURL)
                throw NarrationError.modelDownloadFailed(name: modelFileName, underlying: nil)
            }
            try fm.moveItem(at: tempURL, to: dest)
            progress(1.0)
            return dest
        }
    }

    extension NSData {
        /// Reinterprets raw tensor bytes as a Float32 array (the ONNX `waveform`
        /// output is fp32 even though the model's weights are fp16).
        fileprivate func toFloatArray() -> [Float] {
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
