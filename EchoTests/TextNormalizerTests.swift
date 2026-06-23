// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct TextNormalizerTests {
    @Test(arguments: [
        ("Dr. Smith arrived.", "Doctor Smith arrived."),
        ("St. Mary on St. James St.", "Saint Mary on Saint James Street."),
        ("It cost 1,200 dollars.", "It cost 1200 dollars."),
        ("See e.g. chapter 3.", "See for example chapter 3."),
        ("A pause — then silence.", "A pause, then silence."),
        ("A pause – then silence.", "A pause, then silence."),  // spaced en dash
        ("A pause - then silence.", "A pause, then silence."),  // spaced ASCII hyphen
        ("Chapter IV begins.", "Chapter 4 begins."),
    ])
    func normalizes(_ input: String, _ expected: String) {
        #expect(TextNormalizer.normalize(input) == expected)
    }

    @Test func leavesIntraWordHyphenForTheG2P() {
        // A hyphenated compound (no surrounding spaces) is NOT a sentence pause —
        // it must pass through untouched so the G2P reads it as a word break.
        #expect(TextNormalizer.normalize("a rough-and-ready fix") == "a rough-and-ready fix")
    }

    @Test func stripsThousandsSeparatorInNumbers() {
        #expect(TextNormalizer.normalize("12,345,678") == "12345678")
    }

    @Test func leavesPlainProseUnchanged() {
        #expect(TextNormalizer.normalize("The quick brown fox.") == "The quick brown fox.")
    }
}
