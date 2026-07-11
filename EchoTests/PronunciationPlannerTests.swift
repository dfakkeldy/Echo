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

    @Test func planToleratesUnphonemizableGlyphsWithoutAbortingRender() throws {
        // Ordinary book text can contain glyphs the lexicon-only G2P can't
        // pronounce (symbols, emoji, even a literal ❓). Planning must never throw
        // and must never leave an unencodable marker for `validatedIDs` — the
        // whole-chapter-abort regression from PR #429. Today's MisakiSwift maps
        // these to a schwa or "" so the marker never actually reaches the strip,
        // but the end-to-end invariant this pins holds regardless of that: a weird
        // glyph never bricks the render.
        for input in ["hi 🎉 there", "the ❓ mark", "hi § there", "☭"] {
            let plan = try PronunciationPlanner().plan(
                displayText: input, g2pInputText: input)
            #expect(!plan.phonemes.contains(KokoroPhonemeVocab.oovMarker))
            #expect(plan.phonemeIDs.first == KokoroPhonemeVocab.boundaryTokenId)
            #expect(plan.phonemeIDs.last == KokoroPhonemeVocab.boundaryTokenId)
        }
    }
}
