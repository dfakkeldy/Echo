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
                let ids = vocab.ids(forPhonemes: phonemes) // BOS/EOS wrapped
                let refS = pack.refS(forPhonemeCount: phonemes.count) // clamped
                return PipelineInputs(
                    ids: ids,
                    attentionMask: [Int32](repeating: 1, count: ids.count),
                    refS: refS)
            }
        }

        // MARK: - TTSEngine

        func prepare() async throws {
            // Coalesce concurrent prepare() calls onto a single download + compile.
            if let task = initializationTask {
                try await task.value
                return
            }
            let task = Task<Void, Error> { [logger] in
                let dir = try await NarrationModelStore.shared.ensureModels(progress: nil)
                // KokoroPipeline.init compiles every .mlpackage synchronously
                // (MLModel.compileModel) — heavy, but we're off the main actor.
                let built = try KokoroPipeline(
                    modelsDirectory: dir,
                    buckets: NarrationModelStore.keptBucketSeconds,
                    linearWeights: NarrationModelStore.hnsfLinearWeights,
                    linearBias: NarrationModelStore.hnsfLinearBias)
                await self.setPipeline(built)
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
#endif
