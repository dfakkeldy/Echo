// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct AutoExportMarkdownTests {
    private var book: AutoExportMarkdown.BookContext {
        AutoExportMarkdown.BookContext(
            id: "file:///books/tides/",
            title: "The Field Guide to Tides",
            author: "M. Ostrander",
            chapters: [
                StudyNotesExportService.ChapterEntry(
                    title: "1. Reading the Water",
                    startSeconds: 0
                ),
                StudyNotesExportService.ChapterEntry(
                    title: "2. Why Two Tides a Day",
                    startSeconds: 1_800
                ),
            ]
        )
    }

    @Test func renderIsDeterministicWithStableMarkersAndChapterAttribution() throws {
        let bookmark = Bookmark(
            id: try #require(UUID(uuidString: "7C4A8D09-1E4B-4F6A-9C0D-2B5E8A7F3C11")),
            title: "Spring tide mechanics",
            timestamp: 2_472,
            note: "Alignment stacks the bulges",
            voiceMemoFileName: "memo.m4a",
            latitude: 45.5017,
            longitude: -73.5673,
            placeName: "Sample Pier"
        )
        let note = StudyNotesExportService.Note(
            id: "note-1",
            text: "Neap = nipped range",
            timestamp: 760,
            createdAt: "2026-07-01T20:58:31Z"
        )
        let card = StudyNotesExportService.Card(
            id: "card-1",
            front: "What is slack water?",
            back: "Near-zero flow at reversal",
            timestamp: 3_483,
            endTimestamp: nil,
            tags: "tides",
            media: ["snippet.m4a": URL(fileURLWithPath: "/tmp/snippet.m4a")],
            createdAt: "2026-07-01T21:40:12Z"
        )

        let first = AutoExportMarkdown.render(
            book: book,
            bookmarks: [bookmark],
            notes: [note],
            cards: [card]
        )
        let second = AutoExportMarkdown.render(
            book: book,
            bookmarks: [bookmark],
            notes: [note],
            cards: [card]
        )

        #expect(first == second)
        #expect(first.hasPrefix("---\ntype: echo-study-export\nversion: 1\n"))
        #expect(first.contains("book: \"The Field Guide to Tides\""))
        #expect(first.contains("author: \"M. Ostrander\""))
        #expect(first.contains("book_key: \(AutoExportMarkdown.bookKey(bookID: book.id))"))

        #expect(first.contains("<!-- echo:bookmark 7C4A8D09-1E4B-4F6A-9C0D-2B5E8A7F3C11 -->"))
        #expect(first.contains("<!-- echo:note note-1 -->"))
        #expect(first.contains("<!-- echo:card card-1 -->"))

        #expect(first.contains("- Chapter: 2. Why Two Tides a Day"))
        #expect(first.contains("- Chapter: 1. Reading the Water"))

        #expect(first.contains(
            "- Open in Echo: echoaudio://open/bookmark/7C4A8D09-1E4B-4F6A-9C0D-2B5E8A7F3C11"
        ))

        #expect(first.contains("- Voice memo: attached in Echo (not exported)"))
        #expect(first.contains("- Media: snippet.m4a (attached in Echo; not exported)"))
        #expect(!first.contains("assets/"))
        #expect(!first.contains("45.5017"))
        #expect(!first.contains("-73.5673"))
        #expect(!first.contains("Sample Pier"))
    }

    @Test func fileNamesAreStablePerBookAndDistinctAcrossTitleCollisions() {
        let a = AutoExportMarkdown.fileName(bookID: "file:///books/a/", title: "Same Title")
        let b = AutoExportMarkdown.fileName(bookID: "file:///books/b/", title: "Same Title")

        #expect(a != b)
        #expect(a.hasSuffix(".md"))
        #expect(a.contains(AutoExportMarkdown.bookKey(bookID: "file:///books/a/")))

        let renamed = AutoExportMarkdown.fileName(bookID: "file:///books/a/", title: "New Title")
        #expect(renamed.contains(AutoExportMarkdown.bookKey(bookID: "file:///books/a/")))
        #expect(renamed != a)
    }

    @Test func timestamplessCapturesRenderWithoutChapterOrClock() {
        let note = StudyNotesExportService.Note(
            id: "note-2",
            text: "General thought",
            timestamp: nil,
            createdAt: "2026-07-01T22:00:00Z"
        )
        let output = AutoExportMarkdown.render(
            book: book,
            bookmarks: [],
            notes: [note],
            cards: []
        )

        #expect(output.contains("### Note"))
        #expect(!output.contains("- Chapter:"))
    }
}
