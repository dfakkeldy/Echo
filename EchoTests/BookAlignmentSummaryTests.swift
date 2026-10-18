// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

/// Tests for `BookAlignmentSummary` — the answer to "is this EPUB actually
/// aligned to the audio?".
///
/// The distinction these defend is the whole point of the type. At import,
/// `TimelineIngestionFactory` spreads every block across its chapter by word
/// count and stamps it `AlignmentStatus.estimated`. A book that has never been
/// near an aligner therefore *has* a timeline, *does* scroll, and *does*
/// highlight — it just isn't following the audio. Anything that reports
/// "aligned" from the presence of timeline rows is lying, so the state machine
/// keys off real anchors and `lockedAnchor`/`interpolated` blocks instead.
struct BookAlignmentSummaryTests {

    // MARK: - Pure state machine

    @Test func noTextWhenBookHasNoBlocks() {
        let summary = BookAlignmentSummary.make(
            textBlockCount: 0,
            timedBlockCount: 0,
            anchoredBlockCount: 0,
            realAnchorCount: 0,
            totalAnchorCount: 0)
        #expect(summary.state == .noText)
        #expect(summary.coverage == 0)
        #expect(!summary.isAligned)
    }

    /// Text but no timeline at all: the reader cannot follow anything.
    @Test func unalignedWhenTextHasNoTimeline() {
        let summary = BookAlignmentSummary.make(
            textBlockCount: 100,
            timedBlockCount: 0,
            anchoredBlockCount: 0,
            realAnchorCount: 0,
            totalAnchorCount: 0)
        #expect(summary.state == .unaligned)
        #expect(summary.coveragePercent == 0)
    }

    /// THE case the badge exists for: a freshly imported book. Every block has a
    /// word-count estimate, so it scrolls, but no anchor was ever derived from
    /// the audio.
    @Test func estimatedWhenTimelineIsImportGuessOnly() {
        let summary = BookAlignmentSummary.make(
            textBlockCount: 100,
            timedBlockCount: 100,
            anchoredBlockCount: 0,
            realAnchorCount: 0,
            totalAnchorCount: 0)
        #expect(summary.state == .estimated)
        #expect(!summary.isAligned)
    }

    /// Chapter-boundary seeds are structure, not alignment. A book carrying only
    /// those is still an estimate.
    @Test func chapterBoundarySeedsDoNotCountAsAlignment() {
        let summary = BookAlignmentSummary.make(
            textBlockCount: 100,
            timedBlockCount: 100,
            anchoredBlockCount: 0,
            realAnchorCount: 0,
            totalAnchorCount: 12)
        #expect(summary.state == .estimated)
        #expect(summary.totalAnchorCount == 12)
        #expect(summary.realAnchorCount == 0)
    }

    /// Real anchors that resolved onto nothing visible are worth no more than no
    /// anchors — coverage, not anchor count, is what the reader experiences.
    @Test func realAnchorsThatCoverNoVisibleTextStayEstimated() {
        let summary = BookAlignmentSummary.make(
            textBlockCount: 100,
            timedBlockCount: 100,
            anchoredBlockCount: 0,
            realAnchorCount: 40,
            totalAnchorCount: 52)
        #expect(summary.state == .estimated)
    }

    @Test func partialBelowThreshold() {
        let summary = BookAlignmentSummary.make(
            textBlockCount: 100,
            timedBlockCount: 100,
            anchoredBlockCount: 50,
            realAnchorCount: 20,
            totalAnchorCount: 32)
        #expect(summary.state == .partial)
        #expect(summary.coveragePercent == 50)
        #expect(!summary.isAligned)
    }

    /// The threshold is inclusive, and deliberately below 1.0: front and back
    /// matter outside the first/last anchor keep their import estimate even
    /// after a clean run.
    @Test func alignedAtExactlyTheThreshold() {
        let summary = BookAlignmentSummary.make(
            textBlockCount: 100,
            timedBlockCount: 100,
            anchoredBlockCount: 75,
            realAnchorCount: 30,
            totalAnchorCount: 42)
        #expect(BookAlignmentSummary.alignedThreshold == 0.75)
        #expect(summary.state == .aligned)
        #expect(summary.isAligned)
        #expect(summary.coveragePercent == 75)
    }

    @Test func justBelowTheThresholdIsPartial() {
        let summary = BookAlignmentSummary.make(
            textBlockCount: 100,
            timedBlockCount: 100,
            anchoredBlockCount: 74,
            realAnchorCount: 30,
            totalAnchorCount: 42)
        #expect(summary.state == .partial)
    }

    /// Hidden blocks keep their timeline rows, so the anchored count can exceed
    /// the visible-block denominator. Coverage must not report 130%.
    @Test func coverageIsClampedToOneHundredPercent() {
        let summary = BookAlignmentSummary.make(
            textBlockCount: 100,
            timedBlockCount: 130,
            anchoredBlockCount: 130,
            realAnchorCount: 40,
            totalAnchorCount: 52)
        #expect(summary.coveragePercent == 100)
        #expect(summary.state == .aligned)
    }

    @Test func emptyIsTheNoTextSummary() {
        #expect(BookAlignmentSummary.empty.state == .noText)
        #expect(BookAlignmentSummary.empty.textBlockCount == 0)
    }

    // MARK: - Database fixtures

    private func makeDatabase() throws -> DatabaseService {
        let db = try DatabaseService(inMemory: ())
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book-1', 'Test', 3600)")
        }
        return db
    }

    /// Inserts `count` visible (or hidden) blocks named `<prefix>-<i>`.
    private func insertBlocks(
        _ db: DatabaseService,
        prefix: String,
        count: Int,
        hidden: Bool = false
    ) throws -> [String] {
        let ids = (0..<count).map { "\(prefix)-\($0)" }
        try db.write { db in
            for (index, id) in ids.enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO epub_block
                            (id, audiobook_id, spine_href, spine_index, block_index,
                             sequence_index, block_kind, text, is_hidden)
                        VALUES (?, 'book-1', 's0.xhtml', 0, ?, ?, 'paragraph', 'Lorem ipsum.', ?)
                        """,
                    arguments: [id, index, index, hidden])
            }
        }
        return ids
    }

    /// Gives each named block a timeline row with the supplied alignment status.
    private func insertTimeline(
        _ db: DatabaseService,
        blockIDs: [String],
        status: AlignmentStatus
    ) throws {
        try db.write { db in
            for (index, blockID) in blockIDs.enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO timeline_item
                            (id, audiobook_id, item_type, title, audio_start_time,
                             audio_end_time, epub_block_id, alignment_status)
                        VALUES (?, 'book-1', 'paragraph', 'x', ?, ?, ?, ?)
                        """,
                    arguments: [
                        "t-\(blockID)", Double(index) * 10, Double(index) * 10 + 10, blockID,
                        status.rawValue,
                    ])
            }
        }
    }

    private func insertAnchors(
        _ db: DatabaseService,
        blockIDs: [String],
        source: AlignmentAnchorRecord.Source
    ) throws {
        try db.write { db in
            for blockID in blockIDs {
                try db.execute(
                    sql: """
                        INSERT INTO alignment_anchor
                            (id, audiobook_id, epub_block_id, audio_time, anchor_kind, source)
                        VALUES (?, 'book-1', ?, 0, 'point', ?)
                        """,
                    arguments: ["a-\(source.rawValue)-\(blockID)", blockID, source.rawValue])
            }
        }
    }

    // MARK: - Loading

    @Test func loadReportsNoTextForABookWithoutBlocks() throws {
        let db = try makeDatabase()
        let summary = try BookAlignmentSummary.load(audiobookID: "book-1", db: db.writer)
        #expect(summary == .empty)
    }

    /// End-to-end shape of a just-imported book: 20 estimated blocks, chapter
    /// seeds only. Must not read as aligned.
    @Test func loadClassifiesAFreshImportAsEstimated() throws {
        let db = try makeDatabase()
        let blocks = try insertBlocks(db, prefix: "b", count: 20)
        try insertTimeline(db, blockIDs: blocks, status: .estimated)
        try insertAnchors(db, blockIDs: Array(blocks.prefix(3)), source: .chapterBoundary)

        let summary = try BookAlignmentSummary.load(audiobookID: "book-1", db: db.writer)
        #expect(summary.state == .estimated)
        #expect(summary.textBlockCount == 20)
        #expect(summary.totalAnchorCount == 3)
        #expect(summary.realAnchorCount == 0)
        #expect(summary.anchoredBlockCount == 0)
    }

    @Test func loadClassifiesAnAlignedBook() throws {
        let db = try makeDatabase()
        let blocks = try insertBlocks(db, prefix: "b", count: 20)
        // 16 of 20 resolve through real anchors — 80%, over the threshold.
        try insertTimeline(db, blockIDs: Array(blocks.prefix(4)), status: .lockedAnchor)
        try insertTimeline(db, blockIDs: Array(blocks[4..<16]), status: .interpolated)
        try insertTimeline(db, blockIDs: Array(blocks[16...]), status: .estimated)
        try insertAnchors(db, blockIDs: Array(blocks.prefix(4)), source: .autoAlignment)
        try insertAnchors(db, blockIDs: Array(blocks.prefix(2)), source: .chapterBoundary)

        let summary = try BookAlignmentSummary.load(audiobookID: "book-1", db: db.writer)
        #expect(summary.state == .aligned)
        #expect(summary.anchoredBlockCount == 16)
        #expect(summary.coveragePercent == 80)
        #expect(summary.realAnchorCount == 4)
        #expect(summary.totalAnchorCount == 6)
    }

    @Test func loadClassifiesAThinlyCoveredBookAsPartial() throws {
        let db = try makeDatabase()
        let blocks = try insertBlocks(db, prefix: "b", count: 20)
        try insertTimeline(db, blockIDs: Array(blocks.prefix(5)), status: .lockedAnchor)
        try insertTimeline(db, blockIDs: Array(blocks[5...]), status: .estimated)
        try insertAnchors(db, blockIDs: Array(blocks.prefix(5)), source: .autoAlignment)

        let summary = try BookAlignmentSummary.load(audiobookID: "book-1", db: db.writer)
        #expect(summary.state == .partial)
        #expect(summary.coveragePercent == 25)
    }

    /// Hidden blocks are not readable, so they must leave the denominator. A
    /// book whose visible half is fully anchored is aligned, even though half
    /// its rows are hidden.
    @Test func loadExcludesHiddenBlocksFromCoverage() throws {
        let db = try makeDatabase()
        let visible = try insertBlocks(db, prefix: "v", count: 10)
        let hidden = try insertBlocks(db, prefix: "h", count: 10, hidden: true)
        try insertTimeline(db, blockIDs: visible, status: .lockedAnchor)
        try insertTimeline(db, blockIDs: hidden, status: .estimated)
        try insertAnchors(db, blockIDs: visible, source: .autoAlignment)

        let summary = try BookAlignmentSummary.load(audiobookID: "book-1", db: db.writer)
        #expect(summary.textBlockCount == 10)
        #expect(summary.state == .aligned)
        #expect(summary.coveragePercent == 100)
    }

    /// A second book's rows must not leak into the first book's counts.
    @Test func loadIsScopedToOneBook() throws {
        let db = try makeDatabase()
        let blocks = try insertBlocks(db, prefix: "b", count: 10)
        try insertTimeline(db, blockIDs: blocks, status: .estimated)
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book-2', 'Other', 60)")
            try db.execute(
                sql: """
                    INSERT INTO epub_block
                        (id, audiobook_id, spine_href, spine_index, block_index,
                         sequence_index, block_kind, text, is_hidden)
                    VALUES ('other-0', 'book-2', 's0.xhtml', 0, 0, 0, 'paragraph', 'x', 0)
                    """)
            try db.execute(
                sql: """
                    INSERT INTO alignment_anchor
                        (id, audiobook_id, epub_block_id, audio_time, anchor_kind, source)
                    VALUES ('other-a', 'book-2', 'other-0', 0, 'point', ?)
                    """,
                arguments: [AlignmentAnchorRecord.Source.autoAlignment.rawValue])
        }

        let summary = try BookAlignmentSummary.load(audiobookID: "book-1", db: db.writer)
        #expect(summary.textBlockCount == 10)
        #expect(summary.totalAnchorCount == 0)
        #expect(summary.state == .estimated)
    }
}
