// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS) || os(macOS)
    import Foundation

    /// Chooses per utterance, including mixed narrator/character voice plans.
    /// The unused model stays unloaded and existing Kokoro IDs retain their engine.
    actor NarrationEngineRouter: TTSEngine {
        private let makeKokoro: @Sendable () -> any TTSEngine
        private let makePhonon: @Sendable () -> any TTSEngine
        private var kokoro: (any TTSEngine)?
        private var phonon: (any TTSEngine)?

        init(
            makeKokoro: @escaping @Sendable () -> any TTSEngine,
            makePhonon: @escaping @Sendable () -> any TTSEngine
        ) {
            self.makeKokoro = makeKokoro
            self.makePhonon = makePhonon
        }

        private func engine(for voice: VoiceID) -> any TTSEngine {
            if VoiceCatalog.phononName(for: voice) != nil {
                if let phonon { return phonon }
                let engine = makePhonon()
                phonon = engine
                return engine
            }
            if let kokoro { return kokoro }
            let engine = makeKokoro()
            kokoro = engine
            return engine
        }

        func prepare() async throws { try await prepare(progress: { _ in }) }
        func prepare(
            progress: @escaping @Sendable (NarrationPrepareProgress) -> Void
        ) async throws {
            try await prepare(voice: VoiceCatalog.default.id, progress: progress)
        }

        func prepare(
            voice: VoiceID, progress: @escaping @Sendable (NarrationPrepareProgress) -> Void
        ) async throws {
            try await engine(for: voice).prepare(progress: progress)
        }

        func synthesize(_ text: String, voice: VoiceID) async throws -> TTSChunk {
            try await engine(for: voice).synthesize(text, voice: voice)
        }

        func synthesize(_ chunk: PlannedSynthesisChunk, voice: VoiceID) async throws -> TTSChunk {
            try await engine(for: voice).synthesize(chunk, voice: voice)
        }

        func unload() async {
            let priorKokoro = kokoro
            let priorPhonon = phonon
            kokoro = nil
            phonon = nil
            await priorKokoro?.unload()
            await priorPhonon?.unload()
        }
    }
#endif
