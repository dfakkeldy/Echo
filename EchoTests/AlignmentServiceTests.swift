// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
struct AlignmentServiceTests {

    /// Sets up a database with an audiobook and EPUB blocks — but NO timeline
    /// items. This mirrors the state the app is in when a book was loaded for
    /// playback before its EPUB finished importing, or after a re-import wiped
    /// and re-created blocks under new IDs: `timeline_item` has no rows for
    /// these block IDs.
    private func setupBlocksOnlyDB() throws -> (DatabaseService, String) {
        let db = try DatabaseService(inMemory: ())
        let audiobookID = "book-1"

        try db.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book-1', 'Test', 3600)")
        }

        // Create EPUB blocks at known sequence indices.
        let blocks: [EPubBlockRecord] = [
            EPubBlockRecord(
                id: "b0", audiobookID: audiobookID, spineHref: "ch1.xhtml",
                spineIndex: 0, blockIndex: 0, sequenceIndex: 0,
                blockKind: "paragraph", text: "Block 0", chapterIndex: 0, isHidden: false),
            EPubBlockRecord(
                id: "b1", audiobookID: audiobookID, spineHref: "ch1.xhtml",
                spineIndex: 0, blockIndex: 1, sequenceIndex: 10,
                blockKind: "paragraph", text: "Block 1", chapterIndex: 0, isHidden: false),
            EPubBlockRecord(
                id: "b2", audiobookID: audiobookID, spineHref: "ch1.xhtml",
                spineIndex: 0, blockIndex: 2, sequenceIndex: 20,
                blockKind: "paragraph", text: "Block 2", chapterIndex: 0, isHidden: false),
            EPubBlockRecord(
                id: "b3", audiobookID: audiobookID, spineHref: "ch1.xhtml",
                spineIndex: 0, blockIndex: 3, sequenceIndex: 30,
                blockKind: "paragraph", text: "Block 3", chapterIndex: 0, isHidden: false),
            EPubBlockRecord(
                id: "b4", audiobookID: audiobookID, spineHref: "ch1.xhtml",
                spineIndex: 0, blockIndex: 4, sequenceIndex: 40,
                blockKind: "paragraph", text: "Block 4", chapterIndex: 0, isHidden: true),
        ]
        try EPubBlockDAO(db: db.writer).insertAll(blocks)

        return (db, audiobookID)
    }

    /// Sets up a database with an audiobook, EPUB blocks, and timeline items for alignment testing.
    private func setupAlignmentDB() throws -> (DatabaseService, String) {
        let (db, audiobookID) = try setupBlocksOnlyDB()
        let blocks = try EPubBlockDAO(db: db.writer).blocks(for: audiobookID)

        // Create timeline items linked to the blocks.
        var timelineItems: [TimelineItem] = []
        for block in blocks {
            let item = TimelineItem(
                id: "ti-\(block.id)",
                audiobookID: audiobookID,
                itemType: .textSegment,
                title: block.text ?? "",
                textPayload: block.text,
                audioStartTime: -1,
                audioEndTime: nil,
                epubSequenceIndex: block.sequenceIndex,
                granularityLevel: .paragraph,
                isEnabled: !block.isHidden,
                sourceTable: "epub_block",
                sourceRowid: block.id,
                epubBlockID: block.id,
                timestampSource: TimestampSource.none.rawValue,
                alignmentStatus: AlignmentStatus.unaligned.rawValue,
                alignmentConfidence: nil
            )
            timelineItems.append(item)
        }
        try TimelineDAO(db: db.writer).ingest(timelineItems)

        return (db, audiobookID)
    }

    // MARK: - Anchor tests

    @Test func twoAnchorsInterpolateMiddleBlocks() throws {
        let (db, audiobookID) = try setupAlignmentDB()
        let service = AlignmentService(db: db.writer, audiobookID: audiobookID)

        // Anchor b0 at time 0, b3 at time 120
        try service.moveBlockToCurrentTime(blockID: "b0", time: 0)
        try service.moveBlockToCurrentTime(blockID: "b3", time: 120)

        // b1 (seq 10) should interpolate: 0 + (10/30)*120 = 40
        // b2 (seq 20) should interpolate: 0 + (20/30)*120 = 80
        let items = try TimelineDAO(db: db.writer).items(for: audiobookID)

        let b1 = items.first { $0.epubBlockID == "b1" }
        #expect(b1?.alignmentStatus == AlignmentStatus.interpolated.rawValue)
        #expect(abs((b1?.audioStartTime ?? 0) - 40.0) < 1.0)

        let b2 = items.first { $0.epubBlockID == "b2" }
        #expect(b2?.alignmentStatus == AlignmentStatus.interpolated.rawValue)
        #expect(abs((b2?.audioStartTime ?? 0) - 80.0) < 1.0)
    }

    @Test func recalculationSetsParagraphEndTimesFromNextVisibleBlock() throws {
        let (db, audiobookID) = try setupAlignmentDB()
        let service = AlignmentService(db: db.writer, audiobookID: audiobookID)

        try service.moveBlockToCurrentTime(blockID: "b0", time: 0)
        try service.moveBlockToCurrentTime(blockID: "b3", time: 120)

        let items = try TimelineDAO(db: db.writer).items(for: audiobookID)
        let b1 = try #require(items.first { $0.epubBlockID == "b1" })
        let b2 = try #require(items.first { $0.epubBlockID == "b2" })

        #expect(abs((b1.audioEndTime ?? -1) - b2.audioStartTime) < 0.01)
    }

    @Test func lockedAnchorsHavePrecedence() throws {
        let (db, audiobookID) = try setupAlignmentDB()
        let service = AlignmentService(db: db.writer, audiobookID: audiobookID)

        // Anchor b0 at time 0 and b2 at time 100
        try service.moveBlockToCurrentTime(blockID: "b0", time: 0)
        try service.moveBlockToCurrentTime(blockID: "b2", time: 100)

        let items = try TimelineDAO(db: db.writer).items(for: audiobookID)

        let b0 = items.first { $0.epubBlockID == "b0" }
        #expect(b0?.alignmentStatus == AlignmentStatus.lockedAnchor.rawValue)
        #expect(b0?.audioStartTime == 0)
        #expect(b0?.timestampSource == TimestampSource.lockedAnchor.rawValue)
    }

    @Test func movedAnchorUpdatesAffectedRows() throws {
        let (db, audiobookID) = try setupAlignmentDB()
        let service = AlignmentService(db: db.writer, audiobookID: audiobookID)

        // First anchor at time 50
        try service.moveBlockToCurrentTime(blockID: "b2", time: 50)

        var items = try TimelineDAO(db: db.writer).items(for: audiobookID)
        let b2first = items.first { $0.epubBlockID == "b2" }
        #expect(b2first?.audioStartTime == 50)

        // Move same anchor to time 150
        try service.moveBlockToCurrentTime(blockID: "b2", time: 150)

        items = try TimelineDAO(db: db.writer).items(for: audiobookID)
        let b2second = items.first { $0.epubBlockID == "b2" }
        #expect(b2second?.audioStartTime == 150)
    }

    @Test func hiddenBlocksBecomeOmitted() throws {
        let (db, audiobookID) = try setupAlignmentDB()
        let service = AlignmentService(db: db.writer, audiobookID: audiobookID)

        try service.hideBlock(blockID: "b0", reason: "Not in audiobook")

        let items = try TimelineDAO(db: db.writer).items(for: audiobookID)
        let b0 = items.first { $0.epubBlockID == "b0" }
        #expect(b0?.isEnabled == false)
        #expect(b0?.alignmentStatus == AlignmentStatus.omitted.rawValue)
        #expect(b0?.audioStartTime == -1)

        // Block should be marked hidden in epub_block table too
        let blocks = try EPubBlockDAO(db: db.writer).blocks(for: audiobookID)
        let hiddenBlock = blocks.first { $0.id == "b0" }
        #expect(hiddenBlock?.isHidden == true)
    }

    @Test func unhideRestoresBlock() throws {
        let (db, audiobookID) = try setupAlignmentDB()
        let service = AlignmentService(db: db.writer, audiobookID: audiobookID)

        try service.hideBlock(blockID: "b1", reason: "test")
        try service.unhideBlock(blockID: "b1")

        let items = try TimelineDAO(db: db.writer).items(for: audiobookID)
        let b1 = items.first { $0.epubBlockID == "b1" }
        #expect(b1?.isEnabled == true)
        #expect(b1?.alignmentStatus != AlignmentStatus.omitted.rawValue)
    }

    @Test func chapterAnchorOperations() throws {
        let (db, audiobookID) = try setupAlignmentDB()
        let service = AlignmentService(db: db.writer, audiobookID: audiobookID)

        try service.anchorChapterStart(blockID: "b0", chapterIndex: 0, time: 0)
        try service.anchorChapterEnd(blockID: "b3", chapterIndex: 0, time: 1800)

        let anchors = try AlignmentAnchorDAO(db: db.writer).anchors(for: audiobookID)
        #expect(anchors.count == 2)
        #expect(anchors.contains(where: { $0.anchorKind == "chapterStart" }))
        #expect(anchors.contains(where: { $0.anchorKind == "chapterEnd" }))
    }

    @Test func searchResultAnchoring() throws {
        let (db, audiobookID) = try setupAlignmentDB()
        let service = AlignmentService(db: db.writer, audiobookID: audiobookID)

        try service.anchorSearchResult(blockID: "b1", time: 25.5)

        let anchors = try AlignmentAnchorDAO(db: db.writer).anchors(for: audiobookID)
        #expect(anchors.count == 1)
        #expect(anchors.first?.source == "searchResult")
        #expect(anchors.first?.audioTime == 25.5)
    }

    // MARK: - Timeline self-heal ("no timestamps after auto-alignment" regression)

    /// Builds an anchor the way `AutoAlignmentService` does for its bulk inserts.
    private func importedAnchor(blockID: String, audiobookID: String, time: TimeInterval)
        -> AlignmentAnchorRecord
    {
        AlignmentAnchorRecord(
            id: "auto-test-\(blockID)",
            audiobookID: audiobookID,
            epubBlockID: blockID,
            audioTime: time,
            audioEndTime: nil,
            anchorKind: AlignmentAnchorRecord.AnchorKind.point.rawValue,
            source: AlignmentAnchorRecord.Source.imported.rawValue,
            note: nil,
            createdAt: AlignmentService.isoFormatter.string(from: Date()),
            modifiedAt: nil
        )
    }

    @Test func insertAnchorsCreatesTimelineRowsWhenNoneExist() throws {
        // Regression: AutoAlignmentService inserted 304 anchors but the reader
        // showed no timestamps, because recalculateTimeline's UPDATE-only writes
        // matched zero timeline_item rows and vanished silently.
        let (db, audiobookID) = try setupBlocksOnlyDB()
        let service = AlignmentService(db: db.writer, audiobookID: audiobookID)

        try service.insertAnchors([
            importedAnchor(blockID: "b0", audiobookID: audiobookID, time: 0),
            importedAnchor(blockID: "b3", audiobookID: audiobookID, time: 120),
        ])

        let items = try TimelineDAO(db: db.writer).items(for: audiobookID)
        let epubRows = items.filter { $0.epubBlockID != nil }
        #expect(epubRows.count == 5)

        // The reader's visibility filter: epub_block_id IS NOT NULL AND audio_start_time >= 0.
        let readerVisible = epubRows.filter { $0.audioStartTime >= 0 }
        #expect(readerVisible.count == 4)

        let b0 = items.first { $0.epubBlockID == "b0" }
        #expect(b0?.alignmentStatus == AlignmentStatus.lockedAnchor.rawValue)
        #expect(b0?.audioStartTime == 0)

        let b1 = items.first { $0.epubBlockID == "b1" }
        #expect(b1?.alignmentStatus == AlignmentStatus.interpolated.rawValue)
        #expect(abs((b1?.audioStartTime ?? -999) - 40.0) < 1.0)

        // Hidden blocks still get a (disabled, omitted) row so the feed stays consistent.
        let b4 = items.first { $0.epubBlockID == "b4" }
        #expect(b4?.alignmentStatus == AlignmentStatus.omitted.rawValue)
        #expect(b4?.isEnabled == false)
        #expect(b4?.audioStartTime == -1)
    }

    @Test func insertAnchorsHealsTimelineAfterReimportChangedBlockIDs() throws {
        // Re-import scenario: epub_block rows were wiped and re-created under new
        // IDs, but timeline_item still holds rows pointing at the dead IDs.
        let (db, audiobookID) = try setupBlocksOnlyDB()
        let staleItem = TimelineItem(
            id: "epub-stale-0",
            audiobookID: audiobookID,
            itemType: .textSegment,
            title: "Stale block",
            textPayload: "Stale block",
            audioStartTime: 55,
            audioEndTime: nil,
            epubSequenceIndex: 0,
            granularityLevel: .paragraph,
            isEnabled: true,
            sourceTable: "epub_block",
            sourceRowid: "stale-0",
            epubBlockID: "stale-0",
            timestampSource: TimestampSource.lockedAnchor.rawValue,
            alignmentStatus: AlignmentStatus.lockedAnchor.rawValue,
            alignmentConfidence: nil
        )
        try TimelineDAO(db: db.writer).ingest([staleItem])

        let service = AlignmentService(db: db.writer, audiobookID: audiobookID)
        try service.insertAnchors([
            importedAnchor(blockID: "b0", audiobookID: audiobookID, time: 0),
            importedAnchor(blockID: "b3", audiobookID: audiobookID, time: 120),
        ])

        let items = try TimelineDAO(db: db.writer).items(for: audiobookID)

        // Every current block gained a reader-visible row.
        #expect(items.first { $0.epubBlockID == "b0" }?.audioStartTime == 0)
        #expect((items.first { $0.epubBlockID == "b2" }?.audioStartTime ?? -1) > 0)

        // The stale row is left for the next full re-ingestion to clean up —
        // recalculation must not touch rows for blocks it doesn't know about.
        #expect(items.first { $0.id == "epub-stale-0" }?.audioStartTime == 55)
    }

    // MARK: - Synthesized narration: anchoredOnly skips synthetic boundary + interpolation

    /// Builds an anchor the way NarrationService does for a rendered chapter.
    private func synthesizedAnchor(
        blockID: String, audiobookID: String, time: TimeInterval
    ) -> AlignmentAnchorRecord {
        AlignmentAnchorRecord(
            id: "syn-test-\(blockID)",
            audiobookID: audiobookID,
            epubBlockID: blockID,
            audioTime: time,
            audioEndTime: nil,
            anchorKind: AlignmentAnchorRecord.AnchorKind.point.rawValue,
            source: AlignmentAnchorRecord.Source.synthesized.rawValue,
            note: nil,
            createdAt: AlignmentService.isoFormatter.string(from: Date()),
            modifiedAt: nil
        )
    }

    /// With `anchoredOnly: true` (synthesized narration), ONLY blocks carrying a
    /// real anchor get a timestamp. Every un-anchored block keeps
    /// `audio_start_time = -1` — the sentinel the reader's `>= 0` filter excludes —
    /// instead of being pinned to a near-zero synthetic/interpolated time. This is
    /// the read-along front-matter regression: a single narrated chapter must not
    /// project timestamps onto un-narrated front matter.
    @Test func anchoredOnlyKeepsUnanchoredBlocksAtSentinel() throws {
        let (db, audiobookID) = try setupBlocksOnlyDB()

        // Only b2 is anchored (the single rendered/resumed chapter block).
        try AlignmentAnchorDAO(db: db.writer).upsert(
            synthesizedAnchor(blockID: "b2", audiobookID: audiobookID, time: 30))

        let service = AlignmentService(db: db.writer, audiobookID: audiobookID)
        try service.recalculateTimeline(anchoredOnly: true)

        let items = try TimelineDAO(db: db.writer).items(for: audiobookID)

        // The one real-anchored block is a locked anchor at its real time.
        let b2 = items.first { $0.epubBlockID == "b2" }
        #expect(b2?.audioStartTime == 30)
        #expect(b2?.alignmentStatus == AlignmentStatus.lockedAnchor.rawValue)

        // Every un-anchored, visible block stays at the -1 sentinel (NOT interpolated,
        // NOT pinned to a synthetic ~0 boundary).
        for unanchored in ["b0", "b1", "b3"] {
            let row = items.first { $0.epubBlockID == unanchored }
            #expect(row?.audioStartTime == -1, "\(unanchored) should keep the -1 sentinel")
            #expect(row?.alignmentStatus != AlignmentStatus.interpolated.rawValue)
            #expect(row?.alignmentStatus != AlignmentStatus.lockedAnchor.rawValue)
        }

        // Hidden block is omitted, as always.
        let b4 = items.first { $0.epubBlockID == "b4" }
        #expect(b4?.audioStartTime == -1)
        #expect(b4?.alignmentStatus == AlignmentStatus.omitted.rawValue)

        // The reader-visible set (audio_start_time >= 0) is EXACTLY the one
        // narrated block — front matter is not loaded/highlighted.
        let readerVisible = items.filter { $0.epubBlockID != nil && $0.audioStartTime >= 0 }
        #expect(readerVisible.count == 1)
        #expect(readerVisible.first?.epubBlockID == "b2")
    }

    /// The DEFAULT flag value (`anchoredOnly: false`) preserves the original
    /// behavior byte-for-byte: with a single mid-document anchor, the synthetic
    /// first-block boundary + interpolation still fire, so un-anchored blocks DO
    /// receive projected/interpolated timestamps. This guards against the
    /// narration fix regressing manual alignment / auto-align / hide-unhide.
    @Test func defaultFlagPreservesSyntheticBoundaryAndInterpolation() throws {
        let (db, audiobookID) = try setupBlocksOnlyDB()

        // Same single anchor on b2, but recalc with the DEFAULT (anchoredOnly:false).
        try AlignmentAnchorDAO(db: db.writer).upsert(
            synthesizedAnchor(blockID: "b2", audiobookID: audiobookID, time: 30))

        let service = AlignmentService(db: db.writer, audiobookID: audiobookID)
        try service.recalculateTimeline()  // default == false

        let items = try TimelineDAO(db: db.writer).items(for: audiobookID)

        // b2 is still the locked anchor.
        #expect(items.first { $0.epubBlockID == "b2" }?.audioStartTime == 30)

        // The synthetic first-block boundary fires: b0 (the document's first block)
        // gets a real (non-sentinel) projected timestamp, NOT -1.
        let b0 = items.first { $0.epubBlockID == "b0" }
        #expect((b0?.audioStartTime ?? -1) >= 0, "default path must project the first block")

        // And an un-anchored interior block between the boundary and the anchor is
        // interpolated to a real time — i.e. more than just the single anchored
        // block is reader-visible under the default path.
        let readerVisible = items.filter { $0.epubBlockID != nil && $0.audioStartTime >= 0 }
        #expect(
            readerVisible.count > 1,
            "default path interpolates/projects beyond the single anchored block")
    }
}
