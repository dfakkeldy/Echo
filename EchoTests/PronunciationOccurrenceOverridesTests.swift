// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct PronunciationOccurrenceOverridesTests {
    @Test func structuredRewriteCarriesPortableOccurrenceEvidence() throws {
        let overrides = PronunciationOccurrenceOverrides(entries: [
            PronunciationOccurrenceOverride(
                blockID: "blk1",
                wordStart: 6,
                wordEnd: 6,
                word: "Content",
                ipa: "kˈɑntɛnt")
        ])
        let source = "One two three four five six Content seven eight nine ten eleven twelve."

        let result = overrides.rewrite(to: source, blockID: "blk1")
        let decision = try #require(result.decisionSeeds.first)

        #expect(result.text == overrides.apply(to: source, blockID: "blk1"))
        #expect(decision.blockID == "blk1")
        #expect(decision.wordStart == 6)
        #expect(decision.wordEnd == 6)
        #expect(decision.normalizedWord == "content")
        #expect(decision.sourceWord == "Content")
        #expect(
            decision.sourceContext == "two three four five six Content seven eight nine ten eleven")
        #expect(decision.selectedIPA == "kˈɑntɛnt")
        #expect(decision.source == .occurrenceOverride)
        #expect(decision.ruleID == "override.occurrence")
        #expect(decision.rationale == "Accepted override for this source occurrence.")
    }

    @Test func appliesOnlyToMatchingBlockAndWordIndex() {
        let overrides = PronunciationOccurrenceOverrides(entries: [
            PronunciationOccurrenceOverride(
                blockID: "blk1",
                wordStart: 1,
                wordEnd: 1,
                word: "content",
                ipa: "kˈɑntɛnt")
        ])

        #expect(
            overrides.apply(to: "The content stays here.", blockID: "blk1")
                == "The [content](/kˈɑntɛnt/) stays here.")
        #expect(
            overrides.apply(to: "The content stays here.", blockID: "blk2")
                == "The content stays here.")
    }

    @Test func skipsWhenStoredWordNoLongerMatchesSourceText() {
        let overrides = PronunciationOccurrenceOverrides(entries: [
            PronunciationOccurrenceOverride(
                blockID: "blk1",
                wordStart: 1,
                wordEnd: 1,
                word: "content",
                ipa: "kˈɑntɛnt")
        ])

        #expect(
            overrides.apply(to: "The chapter stays here.", blockID: "blk1")
                == "The chapter stays here.")
    }

    @Test func occurrenceWinsOverBookWideOverrideWhenAppliedFirst() {
        let occurrence = PronunciationOccurrenceOverrides(entries: [
            PronunciationOccurrenceOverride(
                blockID: "blk1",
                wordStart: 1,
                wordEnd: 1,
                word: "content",
                ipa: "kˈɑntɛnt")
        ])
        let bookWide = PronunciationOverrides(entries: ["content": "kəntˈɛnt"])
        let text = occurrence.apply(to: "The content stays here.", blockID: "blk1")

        #expect(
            bookWide.apply(to: text)
                == "The [content](/kˈɑntɛnt/) stays here.")
    }
}
