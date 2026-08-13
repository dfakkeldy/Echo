// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor struct AlignmentAnchorDeleteBySourceTests {
    private func seedBook(_ db: DatabaseService, id: String) throws {
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES (?, 'Book', 100)",
                arguments: [id])
        }
        try EPubBlockDAO(db: db.writer).insertAll([
            EPubBlockRecord(
                id: "b0", audiobookID: id, spineHref: "c.xhtml", spineIndex: 0,
                blockIndex: 0, sequenceIndex: 0, blockKind: "paragraph",
                text: "x", chapterIndex: 0, isHidden: false)
        ])
    }

    private func anchor(
        _ id: String, book: String, source: AlignmentAnchorRecord.Source, time: Double
    ) -> AlignmentAnchorRecord {
        AlignmentAnchorRecord(
            id: id, audiobookID: book, epubBlockID: "b0", audioTime: time,
            audioEndTime: nil, anchorKind: AlignmentAnchorRecord.AnchorKind.point.rawValue,
            source: source.rawValue, note: nil,
            createdAt: AlignmentService.isoFormatter.string(from: Date()), modifiedAt: nil)
    }

    @Test func deletesOnlyMatchingSource() throws {
        let db = try DatabaseService(inMemory: ())
        try seedBook(db, id: "bk")
        let dao = AlignmentAnchorDAO(db: db.writer)
        try dao.insert(anchor("a1", book: "bk", source: .transcriptAlignment, time: 1))
        try dao.insert(anchor("a2", book: "bk", source: .transcriptAlignment, time: 2))
        try dao.insert(anchor("h1", book: "bk", source: .moveToNow, time: 3))

        let removed = try dao.deleteAnchors(
            for: "bk", source: AlignmentAnchorRecord.Source.transcriptAlignment.rawValue)

        #expect(removed == 2)
        #expect(try dao.anchors(for: "bk").map(\.id) == ["h1"])
    }

    @Test func scopedToAudiobook() throws {
        let db = try DatabaseService(inMemory: ())
        try seedBook(db, id: "bk1")
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('bk2','B',100)")
        }
        try EPubBlockDAO(db: db.writer).insertAll([
            EPubBlockRecord(
                id: "b1", audiobookID: "bk2", spineHref: "c.xhtml", spineIndex: 0,
                blockIndex: 0, sequenceIndex: 0, blockKind: "paragraph",
                text: "y", chapterIndex: 0, isHidden: false)
        ])
        let dao = AlignmentAnchorDAO(db: db.writer)
        try dao.insert(anchor("a1", book: "bk1", source: .transcriptAlignment, time: 1))
        try dao.insert(anchor("a2", book: "bk2", source: .transcriptAlignment, time: 1))

        let removed = try dao.deleteAnchors(
            for: "bk1", source: AlignmentAnchorRecord.Source.transcriptAlignment.rawValue)

        #expect(removed == 1)
        #expect(try dao.anchors(for: "bk2").count == 1)
    }
}
