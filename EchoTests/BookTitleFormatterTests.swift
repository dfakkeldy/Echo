// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
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

    @Test func folderAuthorGuessUsesGrandparentFolder() {
        let url = URL(fileURLWithPath: "/Users/me/Audiobooks/Ursula Le Guin/The Dispossessed")
        #expect(BookTitleFormatter.folderAuthorGuess(folderURL: url) == "Ursula Le Guin")
    }

    @Test func folderAuthorGuessRejectsAppContainerUUID() {
        // A file at Documents root: the "folder" is Documents and its parent is
        // the app-container UUID, which must never show as an author.
        let url = URL(
            fileURLWithPath:
                "/data/Containers/Data/Application/20B7B52A-CE2D-4585-84F1-6FBE032FC50D/Documents")
        #expect(BookTitleFormatter.folderAuthorGuess(folderURL: url) == nil)
    }

    @Test func folderAuthorGuessRejectsContainerFolders() {
        let url = URL(fileURLWithPath: "/var/mobile/Documents/Some Book")
        #expect(BookTitleFormatter.folderAuthorGuess(folderURL: url) == nil)
        let uuidParent = URL(
            fileURLWithPath: "/x/0C646763-8698-4E61-995A-71A07C1BF738/Book")
        #expect(BookTitleFormatter.folderAuthorGuess(folderURL: uuidParent) == nil)
    }
}
