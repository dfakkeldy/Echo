// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS) || os(macOS)
    import Foundation
    import KokoroPipeline
    import os.log

    /// The fixed-shape Kokoro narration engine — the wedge-free replacement for
    /// the FluidAudio `KokoroTTSEngine`. Chains the validated pipeline:
    ///
    ///   text → MisakiSwift G2P (IPA) → KokoroPhonemeVocab ([Int32] ids)
    ///       → KokoroVoicePack refS (256-dim af_heart row) → KokoroPipeline.synthesize
    ///       → TTSChunk (mono Float32 @ 24 kHz)
    ///
    /// Implements the existing ``TTSEngine`` seam so `NarrationEngineFactory` can
    /// swap it in with one line (Phase 4.2). All CoreML work happens inside
    /// `prepare()` on a background `Task`; `synthesize` reuses the prepared
    /// pipeline (KokoroPipeline.synthesize is synchronous/blocking, serialized by
    /// the actor).
    ///
    /// The pure input-assembly is factored into ``PipelineInputs.make`` so the
    /// G2P → vocab → refS glue is unit-testable without the CoreML model set.
    actor KokoroFixedShapeEngine: TTSEngine {
        private let logger = Logger(category: "KokoroFixed")
        private var pipeline: KokoroPipeline?
        private var initializationTask: Task<Void, Error>?
        /// Fans prepare-progress out to every caller of `prepare(progress:)` —
        /// including one that JOINS an in-flight prepare (e.g. the iOS Listen tap
        /// arriving after a background pre-warm already started the download).
        private var progressFanOut: ProgressFanOut?

        init() {}

        // MARK: - Pure, testable input assembly (no model needed)

        /// The fully-assembled inputs `KokoroPipeline.synthesize` consumes.
        struct PipelineInputs {
            let ids: [Int32]
            let attentionMask: [Int32]
            let refS: [Float]

            /// Mirrors the Python path: G2P → vocab (BOS/EOS-wrapped ids) →
            /// voice-pack refS row (clamped by phoneme length). Pure so the glue
            /// is unit-testable without the CoreML model set.
            static func make(text: String, voice: VoiceID) throws -> PipelineInputs {
                let g2p = KokoroG2P()
                let vocab = try KokoroPhonemeVocab()
                let pack = try KokoroVoicePack(named: voice.rawValue)
                let phonemes = g2p.phonemes(for: text)
                let ids = vocab.ids(forPhonemes: phonemes)  // BOS/EOS wrapped
                let refS = pack.refS(forPhonemeCount: phonemes.count)  // clamped
                return PipelineInputs(
                    ids: ids,
                    attentionMask: [Int32](repeating: 1, count: ids.count),
                    refS: refS)
            }
        }

        // MARK: - TTSEngine

        func prepare() async throws { try await prepare(progress: { _ in }) }

        func prepare(progress: @escaping @Sendable (NarrationPrepareProgress) -> Void) async throws
        {
            // Already prepared → just signal completion to this caller.
            if pipeline != nil {
                progress(.ready)
                return
            }
            // Coalesce concurrent prepares onto a single download + compile, but
            // FAN OUT progress to every caller — including one that joins an
            // in-flight prepare. (A bare pre-warm `prepare()` on iOS starts the
            // init before the Listen tap's `prepare(progress:)`; without fan-out
            // the tap's closure would be dropped and the user would see no
            // feedback through the multi-minute first run.)
            if let task = initializationTask {
                progressFanOut?.add(progress)
                try await task.value
                progress(.ready)  // covers the race where init finished before we subscribed
                return
            }
            let fan = ProgressFanOut()
            fan.add(progress)
            progressFanOut = fan
            let task = Task<Void, Error> { [logger] in
                defer { fan.clear() }
                // Download the pruned model set (was: progress discarded as `nil`).
                let dir = try await NarrationModelStore.shared.ensureModels(
                    progress: { f in fan.emit(.downloadingModels(fraction: f)) })
                // Persist the compiled .mlmodelc next to the packages so the multi-minute
                // CoreML compile happens once ever; renderVersion-keyed via the subdir.
                let compiledDir = dir.appendingPathComponent("compiled", isDirectory: true)
                let built = try KokoroPipeline(
                    modelsDirectory: dir,
                    compiledModelsDirectory: compiledDir,
                    buckets: NarrationModelStore.keptBucketSeconds,
                    linearWeights: NarrationModelStore.hnsfLinearWeights,
                    linearBias: NarrationModelStore.hnsfLinearBias,
                    compileProgress: { done, total in
                        fan.emit(.compilingModels(done: done, total: total))
                    })
                await self.setPipeline(built)
                fan.emit(.ready)
                logger.info("Fixed-shape pipeline ready.")
            }
            initializationTask = task
            try await task.value
        }

        func synthesize(_ text: String, voice: VoiceID) async throws -> TTSChunk {
            try await prepare()
            guard let pipeline else { throw NarrationError.engineUnavailable }
            let inputs = try Self.PipelineInputs.make(text: text, voice: voice)
            let result = try pipeline.synthesize(
                inputIds: inputs.ids,
                attentionMask: inputs.attentionMask,
                refS: inputs.refS,
                speed: 1.0)
            return TTSChunk(
                samples: result.audio,
                sampleRate: 24_000,
                duration: Double(result.audio.count) / 24_000)
        }

        // MARK: - Private

        /// Isolated setter so the detached `Task` in `prepare` can store the
        /// compiled pipeline back onto the actor safely under Swift 6 isolation.
        private func setPipeline(_ pipeline: KokoroPipeline) {
            self.pipeline = pipeline
        }
    }

    /// Thread-safe, ordered fan-out of prepare-progress to one or more
    /// subscribers, so a caller that JOINS an in-flight `prepare` still receives
    /// events. A small locked box rather than the engine actor itself, because
    /// `emit` is called synchronously (and in order: download events, then
    /// compile, then ready) from the non-isolated `NarrationModelStore` /
    /// `KokoroPipeline` progress callbacks.
    final class ProgressFanOut: @unchecked Sendable {
        private let lock = NSLock()
        private var subscribers: [@Sendable (NarrationPrepareProgress) -> Void] = []

        func add(_ subscriber: @escaping @Sendable (NarrationPrepareProgress) -> Void) {
            lock.lock()
            defer { lock.unlock() }
            subscribers.append(subscriber)
        }

        func emit(_ progress: NarrationPrepareProgress) {
            lock.lock()
            let current = subscribers
            lock.unlock()
            for subscriber in current { subscriber(progress) }
        }

        func clear() {
            lock.lock()
            defer { lock.unlock() }
            subscribers.removeAll()
        }
    }
#endif
