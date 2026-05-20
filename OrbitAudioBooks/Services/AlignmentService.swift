import Foundation

// MARK: - Alignment Service

/// Manages manual alignment anchors and timestamp interpolation.
///
/// Anchors are user-created pins that lock an EPUB block to a specific audio
/// time. Timestamps for blocks between anchors are interpolated linearly by
/// `sequence_index`. Blocks in chapters with known start/end boundaries get
/// estimated timestamps; everything else remains unaligned.
///
/// Recalculation updates affected `timeline_item` rows in a single DB
/// transaction to keep the feed consistent.
struct AlignmentService {
    private let db: DatabaseWriter
    private let audiobookID: String

    init(db: DatabaseWriter, audiobookID: String) {
        self.db = db
        self.audiobookID = audiobookID
    }

    // MARK: - Anchor Creation

    /// Anchors a block to the current playback time.
    func moveBlockToCurrentTime(blockID: String, time: TimeInterval) throws {
        try upsertAnchor(
            blockID: blockID,
            time: time,
            endTime: nil,
            kind: .point,
            source: .moveToNow
        )
    }

    /// Anchors a search result to the current playback time.
    func anchorSearchResult(blockID: String, time: TimeInterval) throws {
        try upsertAnchor(
            blockID: blockID,
            time: time,
            endTime: nil,
            kind: .point,
            source: .searchResult
        )
    }

    /// Anchors the start of a chapter.
    func anchorChapterStart(blockID: String, chapterIndex: Int, time: TimeInterval) throws {
        try upsertAnchor(
            blockID: blockID,
            time: time,
            endTime: nil,
            kind: .chapterStart,
            source: .chapterBoundary
        )
    }

    /// Anchors the end of a chapter.
    func anchorChapterEnd(blockID: String, chapterIndex: Int, time: TimeInterval) throws {
        try upsertAnchor(
            blockID: blockID,
            time: time,
            endTime: nil,
            kind: .chapterEnd,
            source: .chapterBoundary
        )
    }

    private func upsertAnchor(
        blockID: String,
        time: TimeInterval,
        endTime: TimeInterval?,
        kind: AlignmentAnchorRecord.AnchorKind,
        source: AlignmentAnchorRecord.Source
    ) throws {
        let anchor = AlignmentAnchorRecord(
            id: "anchor-\(audiobookID)-\(blockID)",
            audiobookID: audiobookID,
            epubBlockID: blockID,
            audioTime: time,
            audioEndTime: endTime,
            anchorKind: kind.rawValue,
            source: source.rawValue,
            note: nil,
            createdAt: Date().ISO8601Format(),
            modifiedAt: Date().ISO8601Format()
        )

        // Delete existing anchor for this block (if any), then insert
        let dao = AlignmentAnchorDAO(db: db)
        if let _ = try? dao.anchor(for: blockID, audiobookID: audiobookID) {
            try dao.delete(id: anchor.id)
        }
        try dao.insert(anchor)
    }

    // MARK: - Hide / Unhide

    func hideBlock(blockID: String, reason: String?) throws {
        let blockDAO = EPubBlockDAO(db: db)
        try blockDAO.hideBlock(id: blockID, reason: reason)

        // Mark corresponding timeline item as omitted
        try db.write { db in
            try db.execute(
                sql: """
                    UPDATE timeline_item
                    SET alignment_status = :status, is_enabled = 0
                    WHERE epub_block_id = :blockID AND audiobook_id = :audiobookID
                    """,
                arguments: [
                    "status": TimelineItem.AlignmentStatus.omitted.rawValue,
                    "blockID": blockID,
                    "audiobookID": audiobookID
                ]
            )
        }
    }

    func unhideBlock(blockID: String) throws {
        let blockDAO = EPubBlockDAO(db: db)
        try blockDAO.unhideBlock(id: blockID)

        // Restore timeline item visibility
        try db.write { db in
            try db.execute(
                sql: """
                    UPDATE timeline_item
                    SET alignment_status = :status, is_enabled = 1
                    WHERE epub_block_id = :blockID AND audiobook_id = :audiobookID
                    """,
                arguments: [
                    "status": TimelineItem.AlignmentStatus.unaligned.rawValue,
                    "blockID": blockID,
                    "audiobookID": audiobookID
                ]
            )
        }
    }

    // MARK: - Recalculation

    /// Recalculates all timeline item timestamps for the audiobook based on
    /// current anchors and chapter boundaries. Runs in a single transaction.
    func recalculateTimeline() throws {
        try db.write { db in
            // Load all anchors sorted by time
            let anchors = try AlignmentAnchorRecord
                .filter(Column("audiobook_id") == audiobookID)
                .order(Column("audio_time"))
                .fetchAll(db)

            // Load all visible EPUB blocks sorted by sequence
            let blocks = try EPubBlockRecord
                .filter(Column("audiobook_id") == audiobookID)
                .filter(Column("is_hidden") == false)
                .order(Column("sequence_index"))
                .fetchAll(db)

            guard !blocks.isEmpty else { return }

            // Build anchor lookup: sequence_index → anchor
            let anchorByBlockID = Dictionary(uniqueKeysWithValues: anchors.map { ($0.epubBlockID, $0) })

            // If no anchors, try to estimate from chapter boundaries
            guard !anchors.isEmpty else {
                estimateFromChapters(db: db, blocks: blocks)
                return
            }

            // Interpolate between anchors
            // Strategy: find the nearest anchor before and after each block
            let anchorSequencePairs: [(anchor: AlignmentAnchorRecord, seq: Int)] = anchors.compactMap { anchor in
                guard let block = try? EPubBlockRecord.fetchOne(db, key: anchor.epubBlockID) else {
                    return nil
                }
                return (anchor, block.sequenceIndex)
            }.sorted { $0.seq < $1.seq }

            guard let firstPair = anchorSequencePairs.first,
                  let lastPair = anchorSequencePairs.last else { return }

            for block in blocks {
                let newTime: TimeInterval
                let status: String
                let source: String

                if let anchor = anchorByBlockID[block.id] {
                    // Locked anchor — use exactly
                    newTime = anchor.audioTime
                    status = TimelineItem.AlignmentStatus.lockedAnchor.rawValue
                    source = TimelineItem.TimestampSource.lockedAnchor.rawValue
                } else if block.sequenceIndex <= firstPair.seq {
                    // Before first anchor — leave unaligned or estimate
                    newTime = -1
                    status = TimelineItem.AlignmentStatus.unaligned.rawValue
                    source = TimelineItem.TimestampSource.none.rawValue
                } else if block.sequenceIndex >= lastPair.seq {
                    // After last anchor — leave unaligned
                    newTime = -1
                    status = TimelineItem.AlignmentStatus.unaligned.rawValue
                    source = TimelineItem.TimestampSource.none.rawValue
                } else {
                    // Between two anchors — interpolate
                    guard let (prev, next) = findSurroundingAnchors(
                        seq: block.sequenceIndex, pairs: anchorSequencePairs
                    ) else {
                        newTime = -1
                        status = TimelineItem.AlignmentStatus.unaligned.rawValue
                        source = TimelineItem.TimestampSource.none.rawValue
                        try updateTimelineItem(db: db, block: block, time: newTime, status: status, source: source)
                        continue
                    }

                    let seqRange = Double(next.seq - prev.seq)
                    let timeRange = next.anchor.audioTime - prev.anchor.audioTime
                    let fraction = Double(block.sequenceIndex - prev.seq) / seqRange
                    newTime = prev.anchor.audioTime + timeRange * fraction
                    status = TimelineItem.AlignmentStatus.interpolated.rawValue
                    source = TimelineItem.TimestampSource.interpolated.rawValue
                }

                try updateTimelineItem(db: db, block: block, time: newTime, status: status, source: source)
            }
        }
    }

    // MARK: - Private Helpers

    private struct AnchorPair {
        let anchor: AlignmentAnchorRecord
        let seq: Int
    }

    private func findSurroundingAnchors(
        seq: Int,
        pairs: [(anchor: AlignmentAnchorRecord, seq: Int)]
    ) -> (prev: AnchorPair, next: AnchorPair)? {
        var prev: (AlignmentAnchorRecord, Int)?
        var next: (AlignmentAnchorRecord, Int)?

        for pair in pairs {
            if pair.seq < seq {
                prev = pair
            } else if pair.seq > seq, next == nil {
                next = pair
                break
            }
        }

        guard let p = prev, let n = next else { return nil }
        return (AnchorPair(anchor: p.0, seq: p.1), AnchorPair(anchor: n.0, seq: n.1))
    }

    /// Estimate timestamps from chapter boundaries when no anchors exist.
    private func estimateFromChapters(db: Database, blocks: [EPubBlockRecord]) throws {
        // Load chapters for this audiobook
        let chapters = try ChapterRecord
            .filter(Column("audiobook_id") == audiobookID)
            .order(Column("sort_order"))
            .fetchAll(db)

        for block in blocks {
            let newTime: TimeInterval
            let status: String

            if let chapterIdx = block.chapterIndex,
               chapters.indices.contains(chapterIdx) {
                let ch = chapters[chapterIdx]
                // Estimate: distribute blocks evenly within the chapter
                let blocksInChapter = blocks.filter { $0.chapterIndex == chapterIdx }
                if let firstBlock = blocksInChapter.first,
                   let blockPos = blocksInChapter.firstIndex(where: { $0.id == block.id }) {
                    let count = Double(max(1, blocksInChapter.count))
                    let fraction = Double(blockPos) / count
                    let chDuration = ch.endSeconds - ch.startSeconds
                    newTime = ch.startSeconds + chDuration * fraction
                    status = TimelineItem.AlignmentStatus.estimated.rawValue
                } else {
                    newTime = -1
                    status = TimelineItem.AlignmentStatus.unaligned.rawValue
                }
            } else {
                newTime = -1
                status = TimelineItem.AlignmentStatus.unaligned.rawValue
            }

            let source = newTime >= 0
                ? TimelineItem.TimestampSource.estimated.rawValue
                : TimelineItem.TimestampSource.none.rawValue

            try updateTimelineItem(db: db, block: block, time: newTime, status: status, source: source)
        }
    }

    private func updateTimelineItem(
        db: Database,
        block: EPubBlockRecord,
        time: TimeInterval,
        status: String,
        source: String
    ) throws {
        try db.execute(
            sql: """
                UPDATE timeline_item
                SET audio_start_time = :time,
                    timestamp_source = :source,
                    alignment_status = :status
                WHERE epub_block_id = :blockID
                  AND audiobook_id = :audiobookID
                """,
            arguments: [
                "time": time,
                "source": source,
                "status": status,
                "blockID": block.id,
                "audiobookID": audiobookID
            ]
        )
    }
}
