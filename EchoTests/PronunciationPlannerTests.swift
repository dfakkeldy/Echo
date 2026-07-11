// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct PronunciationPlannerTests {
    @Test func planCapturesExactResolvedInputsAndFallbackEvidence() throws {
        let plan = try PronunciationPlanner().plan(
            displayText: "The filesystem works.",
            g2pInputText: "The [filesystem](/fˈIl sˌɪstəm/) works."
        )
        #expect(plan.displayText == "The filesystem works.")
        #expect(plan.g2pInputText == "The [filesystem](/fˈIl sˌɪstəm/) works.")
        #expect(plan.phonemes.contains("fˈIl sˌɪstəm"))
        #expect(plan.phonemeIDs.first == KokoroPhonemeVocab.boundaryTokenId)
        #expect(plan.phonemeIDs.last == KokoroPhonemeVocab.boundaryTokenId)
        #expect(plan.wordCount == 3)
        #expect(plan.pronunciationFallbackHits.isEmpty)
    }

    @Test func verifiedUsesOrdinaryLexiconWithoutFallback() throws {
        let plan = try PronunciationPlanner().plan(
            displayText: "The result was verified.",
            g2pInputText: "The result was verified."
        )
        #expect(plan.phonemes.contains("vˈɛɹəfˌId"))
        #expect(plan.pronunciationFallbackHits.allSatisfy { $0.word.lowercased() != "verified" })
    }

    @Test func planResolvedPreservesSuppliedLinkAndDerivesDisplayText() throws {
        let resolved = "[record](/ɹəkˈɔɹd/)"
        let plan = try PronunciationPlanner().planResolved(resolved)

        #expect(plan.displayText == "record")
        #expect(plan.g2pInputText == resolved)
        #expect(plan.phonemes.contains("ɹəkˈɔɹd"))
    }
}
