// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct TextNormalizerTests {
    @Test(arguments: [
        ("Dr. Smith arrived.", "Doctor Smith arrived."),
        ("St. Mary on St. James St.", "Saint Mary on Saint James Street."),
        ("It cost 1,200 dollars.", "It cost one thousand two hundred dollars."),
        ("See e.g. chapter 3.", "See for example chapter 3."),
        ("A pause — then silence.", "A pause, then silence."),
        ("A pause – then silence.", "A pause, then silence."),  // spaced en dash
        ("A pause - then silence.", "A pause, then silence."),  // spaced ASCII hyphen
        ("Chapter IV begins.", "Chapter 4 begins."),
        ("It served 6,000 people.", "It served six thousand people."),
        ("The launch reached 10,000 readers.", "The launch reached ten thousand readers."),
        ("Completion hit 100%.", "Completion hit one hundred percent."),
        (
            "A 1.6% lift became 2500%.",
            "A one point six percent lift became two thousand five hundred percent."
        ),
        ("Mr. Smith met Mrs. Jones.", "Mister Smith met Missus Jones."),
        ("Prof. Adams, i.e. the chair, spoke.", "Professor Adams, that is the chair, spoke."),
        ("Cats vs. dogs, birds, etc. live here.", "Cats versus dogs, birds, et cetera live here."),
    ])
    func normalizes(_ input: String, _ expected: String) {
        #expect(TextNormalizer.normalize(input) == expected)
    }

    @Test(arguments: [
        ("1st", "first"), ("2nd", "second"), ("3rd", "third"), ("4th", "fourth"),
        ("11th", "eleventh"), ("21st", "twenty-first"), ("42nd", "forty-second"),
        ("100th", "one hundredth"),
    ])
    func expandsOrdinals(_ input: String, _ expected: String) {
        #expect(TextNormalizer.normalize(input) == expected)
    }

    @Test func leavesIntraWordHyphenForTheG2P() {
        // A hyphenated compound (no surrounding spaces) is NOT a sentence pause —
        // it must pass through untouched so the G2P reads it as a word break.
        #expect(TextNormalizer.normalize("a rough-and-ready fix") == "a rough-and-ready fix")
    }

    @Test func expandsThousandsSeparatedNumbersToWords() {
        #expect(
            TextNormalizer.normalize("12,345,678")
                == "twelve million, three hundred and forty-five thousand, six hundred and seventy-eight"
        )
    }

    @Test func leavesPlainProseUnchanged() {
        #expect(TextNormalizer.normalize("The quick brown fox.") == "The quick brown fox.")
    }
}
