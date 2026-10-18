// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
@Suite struct ABSBrowsePresentationTests {
    @Test func missingCoverPathDoesNotLoadCover() throws {
        let item = try decodeItem(
            """
            {"id":"it1","libraryId":"lib1","media":{"metadata":{"title":"No Cover"}}}
            """)

        #expect(!ABSBrowsePresentation.shouldLoadCover(for: item))
    }

    @Test func presentCoverPathLoadsCover() throws {
        let item = try decodeItem(
            """
            {"id":"it1","libraryId":"lib1","media":{"coverPath":"/metadata/items/it1/cover",
             "metadata":{"title":"Covered"}}}
            """)

        #expect(ABSBrowsePresentation.shouldLoadCover(for: item))
    }

    @Test func documentOnlyZeroDurationIsSuppressed() throws {
        let item = try decodeItem(
            """
            {"id":"it1","libraryId":"lib1","media":{"duration":0,
             "ebookFile":{"ino":"e1","mimeType":"application/epub+zip","relPath":"book.epub"},
             "metadata":{"title":"EPUB Only"}}}
            """)

        #expect(ABSBrowsePresentation.displayDuration(for: item) == nil)
    }

    @Test func audioDurationIsDisplayedWhenPositive() throws {
        let item = try decodeItem(
            """
            {"id":"it1","libraryId":"lib1","media":{"duration":3600,
             "audioFiles":[{"ino":"a1","mimeType":"audio/mp4","duration":3600}],
             "metadata":{"title":"Audio Book"}}}
            """)

        #expect(ABSBrowsePresentation.displayDuration(for: item) == 3600)
    }

    @Test func positiveDurationWithoutFileArraysIsDisplayed() throws {
        let item = try decodeItem(
            """
            {"id":"it1","libraryId":"lib1","media":{"duration":1800,
             "metadata":{"title":"Older ABS Shape"}}}
            """)

        #expect(ABSBrowsePresentation.displayDuration(for: item) == 1800)
    }

    @Test func htmlDescriptionIsPresentedAsReadableText() throws {
        let item = try decodeItem(
            """
            {"id":"it1","libraryId":"lib1","media":{"metadata":{"title":"HTML",
             "description":"<p>First &amp; second.</p><p>Line<br>break &#8212; ok.</p>"}}}
            """)

        #expect(
            ABSBrowsePresentation.displayDescription(for: item)
                == "First & second.\n\nLine\n\nbreak — ok.")
    }

    private func decodeItem(_ json: String) throws -> ABSLibraryItem {
        try JSONDecoder().decode(ABSLibraryItem.self, from: Data(json.utf8))
    }
}
