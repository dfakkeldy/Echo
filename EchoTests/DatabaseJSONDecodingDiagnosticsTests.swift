// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@Suite struct DatabaseJSONDecodingDiagnosticsTests {
    @Test func absentEPubJSONDecodesToEmptyCollections() throws {
        let block = makeBlock()

        #expect(try block.decodeMarkers().isEmpty)
        #expect(try block.decodeFormats().isEmpty)
    }

    @Test func malformedEPubMarkerJSONThrowsWithRowContext() {
        let block = makeBlock(markers: #"{"not":"an array"}"#)

        let description = thrownDescription {
            _ = try block.decodeMarkers()
        }

        #expect(description.contains("markers"))
        #expect(description.contains("block-1"))
        #expect(description.contains("book-1"))
    }

    @Test func malformedEPubFormatJSONThrowsWithRowContext() {
        let block = makeBlock(textFormats: #"{"not":"an array"}"#)

        let description = thrownDescription {
            _ = try block.decodeFormats()
        }

        #expect(description.contains("text_formats"))
        #expect(description.contains("block-1"))
        #expect(description.contains("book-1"))
    }

    @Test func absentPDFBookmarkStateConvertsToBookmarkWithoutState() throws {
        let bookmark = try makeBookmarkRecord().toModel()

        #expect(bookmark.pdfViewState == nil)
    }

    @Test func malformedPDFBookmarkStateThrowsWithRowContext() {
        let record = makeBookmarkRecord(pdfViewStateJSON: #"{"pageIndex":"wrong"}"#)

        let description = thrownDescription {
            _ = try record.toModel()
        }

        #expect(description.contains("pdf_view_state_json"))
        #expect(description.contains("123E4567-E89B-12D3-A456-426614174001"))
        #expect(description.contains("book-1"))
    }

    @Test func invalidBookmarkIDThrowsWithRowContext() {
        let record = makeBookmarkRecord(id: "not-a-uuid")

        let description = thrownDescription {
            _ = try record.toModel()
        }

        #expect(description.contains("id"))
        #expect(description.contains("not-a-uuid"))
        #expect(description.contains("book-1"))
    }

    @Test func studyNotesExportSkipsCorruptBookmarkRows() throws {
        let database = try DatabaseService(inMemory: ())
        try seedAudiobook(database.writer, id: "book-1")

        try database.writer.write { db in
            var validRecord = makeBookmarkRecord(
                id: "123E4567-E89B-12D3-A456-426614174000",
                title: "Valid bookmark"
            )
            try validRecord.insert(db)

            var invalidRecord = makeBookmarkRecord(
                id: "not-a-uuid",
                title: "Corrupt bookmark"
            )
            try invalidRecord.insert(db)
        }

        let source = StudyNotesExportDatabaseSource(databaseWriter: database.writer)
        let bookmarks = try source.bookmarks(for: "book-1")

        #expect(bookmarks.count == 1)
        #expect(bookmarks.first?.title == "Valid bookmark")
        #expect(bookmarks.first?.id.uuidString == "123E4567-E89B-12D3-A456-426614174000")
    }

    private func thrownDescription(_ operation: () throws -> Void) -> String {
        do {
            try operation()
            Issue.record("Expected persisted JSON decoding to throw")
            return ""
        } catch {
            return String(describing: error)
        }
    }

    private func makeBlock(markers: String? = nil, textFormats: String? = nil) -> EPubBlockRecord {
        EPubBlockRecord(
            id: "block-1",
            audiobookID: "book-1",
            spineHref: "chapter.xhtml",
            spineIndex: 0,
            blockIndex: 3,
            sequenceIndex: 7,
            blockKind: EPubBlockRecord.Kind.paragraph.rawValue,
            text: "Paragraph",
            htmlContent: nil,
            cardColor: nil,
            chapterThemeColor: nil,
            imagePath: nil,
            chapterIndex: 0,
            isHidden: false,
            hiddenReason: nil,
            isFrontMatter: false,
            wordCount: nil,
            markers: markers,
            textFormats: textFormats,
            createdAt: nil,
            modifiedAt: nil
        )
    }

    private func makeBookmarkRecord(
        id: String = "123E4567-E89B-12D3-A456-426614174001",
        title: String = "Bookmark",
        pdfViewStateJSON: String? = nil
    ) -> BookmarkRecord {
        BookmarkRecord(
            id: id,
            audiobookID: "book-1",
            trackID: nil,
            title: title,
            mediaTimestamp: 12,
            note: nil,
            voiceMemoPath: nil,
            imagePath: nil,
            isEnabled: true,
            playlistPosition: nil,
            pdfViewStateJSON: pdfViewStateJSON,
            latitude: nil,
            longitude: nil,
            placeName: nil,
            createdAt: "2026-06-26T00:00:00Z",
            modifiedAt: "2026-06-26T00:00:00Z"
        )
    }

    private func seedAudiobook(_ writer: DatabaseWriter, id: String) throws {
        try writer.write { db in
            var audiobook = AudiobookRecord(
                id: id,
                title: "Test Book",
                author: "Test Author",
                duration: 0,
                fileCount: nil,
                addedAt: "2026-06-26T00:00:00Z"
            )
            try audiobook.insert(db)
        }
    }
}
