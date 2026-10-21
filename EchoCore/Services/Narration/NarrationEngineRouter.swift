// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS) || os(macOS)
    import Foundation

    /// Chooses per utterance, including mixed narrator/character voice plans.
    /// The unused model stays unloaded and existing Kokoro IDs retain their engine.
    actor NarrationEngineRouter: TTSEngine {
        private let kokoro: any TTSEngine
        private let phonon: any TTSEngine

        init(
            kokoro: any TTSEngine, phonon: any TTSEngine
        ) {
            self.kokoro = kokoro
            self.phonon = phonon
        }

        private func engine(for voice: VoiceID) -> any TTSEngine {
            VoiceCatalog.phononName(for: voice) == nil ? kokoro : phonon
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
            await kokoro.unload()
            await phonon.unload()
        }
    }
#endif
