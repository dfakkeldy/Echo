// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS) || os(macOS)
    import Testing

    @testable import Echo

    @Suite struct OnnxKokoroEnginePlannedInputTests {
        private let voice = VoiceID("am_michael")

        @Test func plannedInputsPreserveExactIDsForWaveformAndDuration() throws {
            let generated = try PronunciationPlanner().plan(
                displayText: "live", g2pInputText: "[live](/lˈIv/)")
            let suppliedIDs: [Int32] = [0, 101, 42, 0]
            let planned = PlannedSynthesisChunk(
                displayText: generated.displayText,
                g2pInputText: generated.g2pInputText,
                phonemes: generated.phonemes,
                phonemeIDs: suppliedIDs,
                wordCount: generated.wordCount,
                pronunciationFallbackHits: generated.pronunciationFallbackHits,
                pronunciationEvidenceValidation: generated.pronunciationEvidenceValidation)

            let inputs = try OnnxKokoroEngine.plannedInputs(
                for: planned, voice: voice, frontEnd: KokoroFrontEnd())

            #expect(inputs.waveformIDs == suppliedIDs)
            #expect(inputs.durationIDs == suppliedIDs)
        }

        @Test func plannedInputsUseDisplayWordCountForTiming() throws {
            let planned = try PronunciationPlanner().plan(
                displayText: "New York",
                g2pInputText: "[New York](/nˈu jˈɔɹk/)")
            #expect(
                planned.g2pInputText.split(whereSeparator: { $0.isWhitespace }).count
                    > planned.wordCount)

            let inputs = try OnnxKokoroEngine.plannedInputs(
                for: planned, voice: voice, frontEnd: KokoroFrontEnd())

            #expect(inputs.wordCount == planned.wordCount)
            #expect(inputs.wordCount == 2)
        }

    }
#endif
