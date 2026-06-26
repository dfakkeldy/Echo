// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
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
        #expect(description.contains("bookmark-1"))
        #expect(description.contains("book-1"))
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

    private func makeBookmarkRecord(pdfViewStateJSON: String? = nil) -> BookmarkRecord {
        BookmarkRecord(
            id: "bookmark-1",
            audiobookID: "book-1",
            trackID: nil,
            title: "Bookmark",
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
}
