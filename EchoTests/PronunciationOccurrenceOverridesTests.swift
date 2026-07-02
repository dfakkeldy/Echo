// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import Echo

@Suite struct PronunciationOccurrenceOverridesTests {
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
