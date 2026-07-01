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

    @Test(arguments: [
        ("$5", "five dollars"),
        ("$5.25", "five dollars and twenty-five cents"),
        ("$1.00", "one dollar"),
        ("$0.99", "ninety-nine cents"),
        (
            "The grant was $1,200.50.",
            "The grant was one thousand two hundred dollars and fifty cents."
        ),
    ])
    func expandsDeterministicDollarAmounts(_ input: String, _ expected: String) {
        #expect(TextNormalizer.normalize(input) == expected)
    }

    @Test(arguments: [
        ("Meet at 3:30.", "Meet at three thirty."),
        ("The bell rang at 12:05.", "The bell rang at twelve oh five."),
        ("Open from 9:00 to 10:15.", "Open from nine o'clock to ten fifteen."),
        ("3:07", "three oh seven"),
    ])
    func expandsProseFriendlyTimes(_ input: String, _ expected: String) {
        #expect(TextNormalizer.normalize(input) == expected)
    }

    @Test(arguments: [
        ("John 3:16 stays a citation.", "John 3:16 stays a citation."),
        ("Use a 3:30 ratio.", "Use a 3:30 ratio."),
        ("https://example.com/3:30/path", "https://example.com/3:30/path"),
    ])
    func leavesAmbiguousTimesAlone(_ input: String, _ expected: String) {
        #expect(TextNormalizer.normalize(input) == expected)
    }

    @Test(arguments: [
        ("Updated on 2026-06-30.", "Updated on June thirtieth, twenty twenty-six."),
        (
            "The archive starts on 1999-01-05.",
            "The archive starts on January fifth, nineteen ninety-nine."
        ),
    ])
    func expandsUnambiguousISODates(_ input: String, _ expected: String) {
        #expect(TextNormalizer.normalize(input) == expected)
    }

    @Test(arguments: [
        ("In 1999, the archive moved.", "In nineteen ninety-nine, the archive moved."),
        ("Since 2001, the project changed.", "Since two thousand one, the project changed."),
        ("By 2026, the tool matured.", "By twenty twenty-six, the tool matured."),
        ("The year 1905 was cold.", "The year nineteen oh five was cold."),
    ])
    func expandsLikelyStandaloneYears(_ input: String, _ expected: String) {
        #expect(TextNormalizer.normalize(input) == expected)
    }

    @Test(arguments: [
        ("A$5 stays unsupported.", "A$5 stays unsupported."),
        ("The malformed $5.2 stays literal.", "The malformed $5.2 stays literal."),
        ("The odd $5% token stays literal.", "The odd $5% token stays literal."),
        ("The 1999 files remain.", "The 1999 files remain."),
        ("The 2026-13-30 draft stays literal.", "The 2026-13-30 draft stays literal."),
        ("Version 2026-06 stays literal.", "Version 2026-06 stays literal."),
    ])
    func leavesAmbiguousNaturalnessFormsAlone(_ input: String, _ expected: String) {
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

    @Test(arguments: [
        ("World War II ended.", "World War 2 ended."),
        ("Part IV opens quietly.", "Part 4 opens quietly."),
        ("Act V begins now.", "Act 5 begins now."),
        ("Volume III gathers notes.", "Volume 3 gathers notes."),
        ("Henry VIII arrived.", "Henry the Eighth arrived."),
        ("Elizabeth II arrived.", "Elizabeth the Second arrived."),
        ("Louis XIV arrived.", "Louis the Fourteenth arrived."),
        ("George V arrived.", "George the Fifth arrived."),
    ])
    func normalizesCommonRomanNumeralBookContexts(_ input: String, _ expected: String) {
        #expect(TextNormalizer.normalize(input) == expected)
    }

    @Test(arguments: [
        ("Cats vs. dogs. Birds follow.", "Cats versus dogs. Birds follow."),
        ("Bring stamps, etc. The next day.", "Bring stamps, et cetera. The next day."),
        ("Main St. Their prices rose.", "Main Street. Their prices rose."),
        ("Old St. Paul's was rebuilt.", "Old Saint Paul's was rebuilt."),
        ("Old St. Paul’s was rebuilt.", "Old Saint Paul’s was rebuilt."),
        ("Old St. Paul's...", "Old Saint Paul's..."),
        ("Old St. Paul’s...", "Old Saint Paul’s..."),
        ("Yankees vs. Red Sox tonight.", "Yankees versus Red Sox tonight."),
        ("See e.g. Appendix A.", "See for example Appendix A."),
    ])
    func preservesSentenceEndingPeriodsWhenExpandingAbbreviations(
        _ input: String,
        _ expected: String
    ) {
        #expect(TextNormalizer.normalize(input) == expected)
    }

    @Test(arguments: [
        ("1,000th", "one thousandth"),
        ("12,345th", "twelve thousand, three hundred and forty-fifth"),
    ])
    func expandsCommaGroupedOrdinals(_ input: String, _ expected: String) {
        #expect(TextNormalizer.normalize(input) == expected)
    }

    @Test func leavesPlainProseUnchanged() {
        #expect(TextNormalizer.normalize("The quick brown fox.") == "The quick brown fox.")
    }

    @Test(arguments: [
        "Visit https://example.com/path?x=1.",
        "Email me@example.com before launch.",
        "Run echo-cli qa --work-dir /tmp/render.",
        "Keep rough-and-ready and sourceBlockID stable.",
    ])
    func leavesCodeURLsAndEmailLikeTextStable(_ input: String) {
        #expect(TextNormalizer.normalize(input) == input)
    }
}
