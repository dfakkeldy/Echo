// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

struct BookTitleFormatterTests {

    @Test func humanizesDashSlug() {
        #expect(
            BookTitleFormatter.humanized("system-that-does-the-reviewing")
                == "System That Does The Reviewing")
    }

    @Test func passesThroughHumanAuthoredNames() {
        #expect(
            BookTitleFormatter.humanized("The System That Does the Reviewing")
                == "The System That Does the Reviewing")
    }

    @Test func underscoresBecomeSpaces() {
        #expect(BookTitleFormatter.humanized("kill_it_with_fire") == "Kill It With Fire")
    }

    @Test func preservesInteriorCapitals() {
        #expect(BookTitleFormatter.humanized("EPUB-guide") == "EPUB Guide")
    }

    @Test func storedTitleWins() {
        #expect(
            BookTitleFormatter.displayTitle(
                storedTitle: "The System That Does the Reviewing",
                fallbackName: "system-that-does-the-reviewing")
                == "The System That Does the Reviewing")
    }

    @Test func slugSeededStoredTitleIsHumanized() {
        // LibraryService.rescan seeds AudiobookRecord.title from the folder
        // slug before metadata enrichment — display must humanize it, not
        // echo the raw slug.
        #expect(
            BookTitleFormatter.displayTitle(
                storedTitle: "system-that-does-the-reviewing",
                fallbackName: "system-that-does-the-reviewing")
                == "System That Does The Reviewing")
    }

    @Test func blankStoredTitleFallsBack() {
        #expect(
            BookTitleFormatter.displayTitle(storedTitle: "  ", fallbackName: "dune") == "Dune")
    }
}
