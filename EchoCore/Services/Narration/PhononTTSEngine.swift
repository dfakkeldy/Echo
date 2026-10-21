// SPDX-License-Identifier: GPL-3.0-or-later
#if (os(iOS) || os(macOS)) && canImport(PhononTTS)
    import Foundation
    import PhononTTS

    /// Native Phonon 31M inference. The model owns its text normalization;
    /// Kokoro's IPA markup and duration head are never sent to this runtime.
    actor PhononTTSEngine: TTSEngine {
        private var model: Phonon?
        private var loading: Task<Phonon, Error>?
        private var synthesis: (id: UUID, task: Task<TTSChunk, Error>)?
        private var selectedVoice: String?
        private var generation = 0

        func prepare() async throws { try await prepare(progress: { _ in }) }

        func prepare(
            progress: @escaping @Sendable (NarrationPrepareProgress) -> Void
        ) async throws {
            if model != nil {
                progress(.ready)
                return
            }
            let loadGeneration = generation
            if let loading {
                let loaded = try await loading.value
                guard generation == loadGeneration else { throw CancellationError() }
                model = loaded
                progress(.ready)
                return
            }
            let task = Task {
                let directory = try await PhononModelStore.shared.models(progress: progress)
                progress(.loadingModel)
                return try await Phonon.load(models: directory, language: .english)
            }
            loading = task
            defer { if generation == loadGeneration { loading = nil } }
            let loaded = try await task.value
            try Task.checkCancellation()
            guard generation == loadGeneration else { throw CancellationError() }
            model = loaded
            progress(.ready)
        }

        func synthesize(_ chunk: PlannedSynthesisChunk, voice: VoiceID) async throws -> TTSChunk {
            try await synthesize(chunk.displayText, voice: voice)
        }

        func synthesize(_ text: String, voice: VoiceID) async throws -> TTSChunk {
            // Actor reentrancy alone does not serialize setVoice + synthesize:
            // another call could switch the voice between those two awaits.
            let previous = synthesis?.task
            let id = UUID()
            let task = Task {
                _ = await previous?.result
                try Task.checkCancellation()
                return try await self.render(text, voice: voice)
            }
            synthesis = (id, task)
            defer { if synthesis?.id == id { synthesis = nil } }
            return try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
        }

        private func render(_ text: String, voice: VoiceID) async throws -> TTSChunk {
            try Task.checkCancellation()
            let renderGeneration = generation
            guard let name = VoiceCatalog.phononName(for: voice) else {
                throw NarrationError.engineUnavailable
            }
            try await prepare()
            try Task.checkCancellation()
            guard generation == renderGeneration else { throw CancellationError() }
            guard let model else { throw NarrationError.engineUnavailable }
            if selectedVoice != name {
                try await model.setVoice(name)
                try Task.checkCancellation()
                guard generation == renderGeneration else { throw CancellationError() }
                selectedVoice = name
            }
            let samples = try await model.synthesize(text)
            try Task.checkCancellation()
            guard generation == renderGeneration else { throw CancellationError() }
            guard !samples.isEmpty, samples.allSatisfy(\.isFinite) else {
                throw NarrationError.synthesisFailed
            }
            return TTSChunk(
                samples: samples, sampleRate: Phonon.sampleRate,
                duration: Double(samples.count) / Phonon.sampleRate)
        }

        func unload() async {
            generation += 1
            let pending = synthesis?.task
            let preparation = loading
            synthesis = nil
            loading = nil
            model = nil
            selectedVoice = nil
            pending?.cancel()
            preparation?.cancel()
            _ = await pending?.result
            _ = await preparation?.result
        }
    }
#endif
