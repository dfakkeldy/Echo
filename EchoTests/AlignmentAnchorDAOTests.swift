import Testing
import Foundation
import GRDB
@testable import Echo

@MainActor
struct AlignmentAnchorDAOTests {

    /// Pipeline re-runs must clear only their own anchors: Tier 0 title
    /// matches and DTW-mapped anchors. Manual anchors and continuous
    /// background anchors belong to other features and must survive.
    @Test func deleteAutoPipelineAnchorsRemovesOnlyPipelineAnchors() throws {
        let db = try DatabaseService(inMemory: ())
        let audiobookID = "book-1"

        try db.write { db in
            try db.execute(sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book-1', 'Test', 3600)")
        }
        try EPubBlockDAO(db: db.writer).insertAll([
            EPubBlockRecord(id: "b0", audiobookID: audiobookID, spineHref: "ch1.xhtml",
                            spineIndex: 0, blockIndex: 0, sequenceIndex: 0,
                            blockKind: "paragraph", text: "Block 0",
                            chapterIndex: 0, isHidden: false),
        ])

        let dao = AlignmentAnchorDAO(db: db.writer)
        let iso = AlignmentService.isoFormatter
        func anchor(id: String, source: AlignmentAnchorRecord.Source, time: Double) -> AlignmentAnchorRecord {
            AlignmentAnchorRecord(
                id: id, audiobookID: audiobookID, epubBlockID: "b0",
                audioTime: time, audioEndTime: nil,
                anchorKind: AlignmentAnchorRecord.AnchorKind.point.rawValue,
                source: source.rawValue, note: nil,
                createdAt: iso.string(from: Date()), modifiedAt: nil)
        }
        try dao.insert(anchor(id: "auto-tier0-abc", source: .autoAlignment, time: 10))
        try dao.insert(anchor(id: "auto-dtw-def", source: .autoAlignment, time: 20))
        try dao.insert(anchor(id: "auto-continuous-ghi", source: .continuousBackground, time: 30))
        try dao.insert(anchor(id: "anchor-jkl", source: .moveToNow, time: 40))

        let removed = try dao.deleteAutoPipelineAnchors(for: audiobookID)

        // Every machine-made anchor goes (tier 0, DTW, continuous) so a
        // re-run can correct earlier mistakes; human-made anchors survive.
        #expect(removed == 3)
        let survivors = try dao.anchors(for: audiobookID).map(\.id).sorted()
        #expect(survivors == ["anchor-jkl"])
    }

    /// Anchors for other audiobooks are out of scope for the cleanup.
    @Test func deleteAutoPipelineAnchorsScopedToAudiobook() throws {
        let db = try DatabaseService(inMemory: ())
        try db.write { db in
            try db.execute(sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book-1', 'A', 100)")
            try db.execute(sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book-2', 'B', 100)")
        }
        try EPubBlockDAO(db: db.writer).insertAll([
            EPubBlockRecord(id: "b1", audiobookID: "book-1", spineHref: "c.xhtml",
                            spineIndex: 0, blockIndex: 0, sequenceIndex: 0,
                            blockKind: "paragraph", text: "x",
                            chapterIndex: 0, isHidden: false),
            EPubBlockRecord(id: "b2", audiobookID: "book-2", spineHref: "c.xhtml",
                            spineIndex: 0, blockIndex: 0, sequenceIndex: 0,
                            blockKind: "paragraph", text: "y",
                            chapterIndex: 0, isHidden: false),
        ])

        let dao = AlignmentAnchorDAO(db: db.writer)
        let iso = AlignmentService.isoFormatter
        for (id, book, block) in [("auto-tier0-1", "book-1", "b1"), ("auto-tier0-2", "book-2", "b2")] {
            try dao.insert(AlignmentAnchorRecord(
                id: id, audiobookID: book, epubBlockID: block,
                audioTime: 5, audioEndTime: nil,
                anchorKind: AlignmentAnchorRecord.AnchorKind.point.rawValue,
                source: AlignmentAnchorRecord.Source.autoAlignment.rawValue, note: nil,
                createdAt: iso.string(from: Date()), modifiedAt: nil))
        }

        let removed = try dao.deleteAutoPipelineAnchors(for: "book-1")

        #expect(removed == 1)
        #expect(try dao.anchors(for: "book-2").count == 1)
    }
}
