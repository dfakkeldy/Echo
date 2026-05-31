import Foundation
import GRDB
import os.log

/// Manages manual EPUB-to-audio alignment through locked anchors and
/// timestamp interpolation.
///
/// Public operations produce alignment anchors and recalculate affected
/// `timeline_item` rows in a single DB transaction.
struct AlignmentService {
    private static let isoFormatter = ISO8601DateFormatter()

    private let logger = Logger(subsystem: "com.orbitaudiobooks", category: "Alignment")
    private let anchorDAO: AlignmentAnchorDAO
    private let blockDAO: EPubBlockDAO
    private let timelineDAO: TimelineDAO
    private let chapterDAO: ChapterDAO
    private let audiobookID: String

    init(db: DatabaseWriter, audiobookID: String) {
        self.anchorDAO = AlignmentAnchorDAO(db: db)
        self.blockDAO = EPubBlockDAO(db: db)
        self.timelineDAO = TimelineDAO(db: db)
        self.chapterDAO = ChapterDAO(db: db)
        self.audiobookID = audiobookID
    }

    // MARK: - Anchor Operations

    /// Moves a block to the current playback time, creating or updating a locked anchor.
    func moveBlockToCurrentTime(blockID: String, time: TimeInterval) throws {
        let anchor = AlignmentAnchorRecord(
            id: "anchor-\(UUID().uuidString)",
            audiobookID: audiobookID,
            epubBlockID: blockID,
            audioTime: time,
            audioEndTime: nil,
            anchorKind: AlignmentAnchorRecord.AnchorKind.point.rawValue,
            source: AlignmentAnchorRecord.Source.moveToNow.rawValue,
            note: nil,
            createdAt: Self.isoFormatter.string(from: Date()),
            modifiedAt: nil
        )
        // Remove any existing anchor for this block, then insert.
        if let existing = try anchorDAO.anchor(for: audiobookID, epubBlockID: blockID) {
            try anchorDAO.delete(id: existing.id)
        }
        try anchorDAO.upsert(anchor)
        try recalculateTimeline()
    }

    /// Anchors a search result block at a specific time.
    func anchorSearchResult(blockID: String, time: TimeInterval) throws {
        let anchor = AlignmentAnchorRecord(
            id: "anchor-\(UUID().uuidString)",
            audiobookID: audiobookID,
            epubBlockID: blockID,
            audioTime: time,
            audioEndTime: nil,
            anchorKind: AlignmentAnchorRecord.AnchorKind.point.rawValue,
            source: AlignmentAnchorRecord.Source.searchResult.rawValue,
            note: nil,
            createdAt: Self.isoFormatter.string(from: Date()),
            modifiedAt: nil
        )
        if let existing = try anchorDAO.anchor(for: audiobookID, epubBlockID: blockID) {
            try anchorDAO.delete(id: existing.id)
        }
        try anchorDAO.upsert(anchor)
        try recalculateTimeline()
    }

    /// Erases the anchor for the given block ID and recalculates alignment.
    func eraseAnchor(blockID: String) throws {
        if let existing = try anchorDAO.anchor(for: audiobookID, epubBlockID: blockID) {
            try anchorDAO.delete(id: existing.id)
            try recalculateTimeline()
        }
    }

    /// Resets all alignment anchors for this audiobook.
    func resetAlignment() throws {
        try timelineDAO.db.write { db in
            try db.execute(sql: "DELETE FROM alignment_anchor WHERE audiobook_id = ?", arguments: [audiobookID])
        }
        try recalculateTimeline()
    }

    /// Sets a chapter start anchor.
    func anchorChapterStart(blockID: String, chapterIndex: Int, time: TimeInterval) throws {
        let anchor = AlignmentAnchorRecord(
            id: "anchor-\(UUID().uuidString)",
            audiobookID: audiobookID,
            epubBlockID: blockID,
            audioTime: time,
            audioEndTime: nil,
            anchorKind: AlignmentAnchorRecord.AnchorKind.chapterStart.rawValue,
            source: AlignmentAnchorRecord.Source.chapterBoundary.rawValue,
            note: "Chapter \(chapterIndex) start",
            createdAt: Self.isoFormatter.string(from: Date()),
            modifiedAt: nil
        )
        if let existing = try anchorDAO.anchor(for: audiobookID, epubBlockID: blockID) {
            try anchorDAO.delete(id: existing.id)
        }
        try anchorDAO.upsert(anchor)
        try recalculateTimeline()
    }

    /// Sets a chapter end anchor.
    func anchorChapterEnd(blockID: String, chapterIndex: Int, time: TimeInterval) throws {
        let anchor = AlignmentAnchorRecord(
            id: "anchor-\(UUID().uuidString)",
            audiobookID: audiobookID,
            epubBlockID: blockID,
            audioTime: time,
            audioEndTime: nil,
            anchorKind: AlignmentAnchorRecord.AnchorKind.chapterEnd.rawValue,
            source: AlignmentAnchorRecord.Source.chapterBoundary.rawValue,
            note: "Chapter \(chapterIndex) end",
            createdAt: Self.isoFormatter.string(from: Date()),
            modifiedAt: nil
        )
        if let existing = try anchorDAO.anchor(for: audiobookID, epubBlockID: blockID) {
            try anchorDAO.delete(id: existing.id)
        }
        try anchorDAO.upsert(anchor)
        try recalculateTimeline()
    }

    // MARK: - Block Visibility

    func hideBlock(blockID: String, reason: String?) throws {
        try blockDAO.hideBlock(id: blockID, reason: reason)
        try recalculateTimeline()
    }

    func unhideBlock(blockID: String) throws {
        try blockDAO.unhideBlock(id: blockID)
        try recalculateTimeline()
    }

    func hideChapter(chapterIndex: Int, reason: String?) throws {
        try blockDAO.hideChapter(chapterIndex: chapterIndex, audiobookID: audiobookID, reason: reason)
        try recalculateTimeline()
    }

    // MARK: - Timeline Recalculation

    /// Recalculates all affected `timeline_item` rows in one transaction.
    ///
    /// Interpolation rules:
    /// 1. Locked anchors always take precedence
    /// 2. Blocks between two anchors interpolate linearly by `sequence_index`
    ///    using proportional word counts.
    /// 3. Hidden blocks become `alignment_status = omitted`, `is_enabled = false`
    func recalculateTimeline() throws {
        let blocks = try blockDAO.blocks(for: audiobookID)
        let anchors = try anchorDAO.anchors(for: audiobookID)

        guard !blocks.isEmpty else { return }

        // Build lookup maps.
        let anchorTimeByBlockID: [String: TimeInterval] = {
            var dict: [String: TimeInterval] = [:]
            for anchor in anchors {
                dict[anchor.epubBlockID] = anchor.audioTime
            }
            return dict
        }()
        let blockByID: [String: EPubBlockRecord] = {
            var dict: [String: EPubBlockRecord] = [:]
            for block in blocks {
                dict[block.id] = block
            }
            return dict
        }()

        // Pre-compute text positions for proportional interpolation
        let sortedAllBlocks = blocks.sorted { $0.sequenceIndex < $1.sequenceIndex }
        var wordPositionByBlockID: [String: Double] = [:]
        var cumulativeWordCount: Double = 0
        for block in sortedAllBlocks {
            let weight = Double(max(1, block.text?.count ?? 1))
            let center = cumulativeWordCount + weight / 2.0
            wordPositionByBlockID[block.id] = center
            cumulativeWordCount += weight
        }

        let maxEndTime = try? timelineDAO.db.read { db in
            try Double.fetchOne(db, sql: """
                SELECT MAX(audio_end_time)
                FROM timeline_item
                WHERE audiobook_id = ? AND item_type = 'chapterMarker'
                """, arguments: [audiobookID])
        }
        let totalDuration = maxEndTime ?? 1.0

        // Single transaction: all alignment writes batched together.
        try timelineDAO.db.write { db in

            // ── Global flat interpolation ──
            var anchoredBlocks = blocks.filter { anchorTimeByBlockID[$0.id] != nil }
                .sorted { $0.sequenceIndex < $1.sequenceIndex }

            var syntheticAnchorTimes = anchorTimeByBlockID
            if let first = sortedAllBlocks.first, syntheticAnchorTimes[first.id] == nil {
                anchoredBlocks.insert(first, at: 0)
                syntheticAnchorTimes[first.id] = 0.0
            }
            if let last = sortedAllBlocks.last, syntheticAnchorTimes[last.id] == nil {
                anchoredBlocks.append(last)
                syntheticAnchorTimes[last.id] = totalDuration
            }

            for block in blocks {
                let audioStart: TimeInterval
                let timestampSrc: String
                let alignStatus: String

                if block.isHidden {
                    audioStart = -1
                    timestampSrc = TimestampSource.none.rawValue
                    alignStatus = AlignmentStatus.omitted.rawValue
                } else if let lockedTime = syntheticAnchorTimes[block.id], anchorTimeByBlockID[block.id] != nil {
                    audioStart = lockedTime
                    timestampSrc = TimestampSource.lockedAnchor.rawValue
                    alignStatus = AlignmentStatus.lockedAnchor.rawValue
                } else if let lockedTime = syntheticAnchorTimes[block.id] {
                    audioStart = lockedTime
                    timestampSrc = TimestampSource.interpolated.rawValue
                    alignStatus = AlignmentStatus.interpolated.rawValue
                } else if anchoredBlocks.count >= 2,
                          let (prev, next) = findBracketingAnchors(
                              block: block,
                              anchoredBlocks: anchoredBlocks,
                              anchorTimes: syntheticAnchorTimes
                          ) {
                    let prevPos = wordPositionByBlockID[prev.id] ?? 0
                    let nextPos = wordPositionByBlockID[next.id] ?? 0
                    let blockPos = wordPositionByBlockID[block.id] ?? 0
                    guard let prevTime = syntheticAnchorTimes[prev.id],
                          let nextTime = syntheticAnchorTimes[next.id] else {
                        continue
                    }
                    let fraction = (nextPos > prevPos) ? (blockPos - prevPos) / (nextPos - prevPos) : 0
                    audioStart = prevTime + fraction * (nextTime - prevTime)
                    timestampSrc = TimestampSource.interpolated.rawValue
                    alignStatus = AlignmentStatus.interpolated.rawValue
                } else {
                    audioStart = -1
                    timestampSrc = TimestampSource.none.rawValue
                    alignStatus = AlignmentStatus.unaligned.rawValue
                }

                try TimelineDAO.writeAlignment(
                    db: db,
                    epubBlockID: block.id,
                    audiobookID: audiobookID,
                    audioStartTime: audioStart,
                    timestampSource: timestampSrc,
                    alignmentStatus: alignStatus,
                    isEnabled: !block.isHidden
                )
            }
        }

        logger.info("Recalculated timeline for \(audiobookID): \(blocks.count) blocks, \(anchors.count) anchors")
    }

    /// Finds the anchored blocks immediately before and after the given block
    /// by sequence index, for linear interpolation.
    private func findBracketingAnchors(
        block: EPubBlockRecord,
        anchoredBlocks: [EPubBlockRecord],
        anchorTimes: [String: TimeInterval]
    ) -> (prev: EPubBlockRecord, next: EPubBlockRecord)? {
        let sorted = anchoredBlocks.sorted { $0.sequenceIndex < $1.sequenceIndex }
        let blockSeq = block.sequenceIndex

        var prev: EPubBlockRecord?
        var next: EPubBlockRecord?

        for anchored in sorted {
            if anchored.sequenceIndex < blockSeq {
                prev = anchored
            } else if anchored.sequenceIndex > blockSeq, next == nil {
                next = anchored
            }
        }

        guard let prev, let next else { return nil }
        return (prev, next)
    }
}

// MARK: - TimelineDAO Alignment Extension

extension TimelineDAO {
    /// Updates alignment metadata for a timeline item linked to an EPUB block.
    /// Opens its own transaction — suitable for single-call use.
    func updateAlignment(
        epubBlockID: String,
        audiobookID: String,
        audioStartTime: TimeInterval,
        timestampSource: String,
        alignmentStatus: String,
        isEnabled: Bool
    ) throws {
        try db.write { db in
            try Self.writeAlignment(
                db: db,
                epubBlockID: epubBlockID,
                audiobookID: audiobookID,
                audioStartTime: audioStartTime,
                timestampSource: timestampSource,
                alignmentStatus: alignmentStatus,
                isEnabled: isEnabled
            )
        }
    }

    /// Writes alignment within an existing transaction — does NOT open its own.
    /// Fileprivate so `AlignmentService.recalculateTimeline` can batch many calls
    /// inside a single `db.write` block.
    fileprivate static func writeAlignment(
        db: Database,
        epubBlockID: String,
        audiobookID: String,
        audioStartTime: TimeInterval,
        timestampSource: String,
        alignmentStatus: String,
        isEnabled: Bool
    ) throws {
        try db.execute(
            sql: """
                UPDATE timeline_item
                SET audio_start_time = :audioStartTime,
                    timestamp_source = :timestampSource,
                    alignment_status = :alignmentStatus,
                    is_enabled = :isEnabled,
                    modified_at = :now
                WHERE epub_block_id = :epubBlockID
                  AND audiobook_id = :audiobookID
                """,
            arguments: [
                "audioStartTime": audioStartTime,
                "timestampSource": timestampSource,
                "alignmentStatus": alignmentStatus,
                "isEnabled": isEnabled,
                "now": Date().ISO8601Format(),
                "epubBlockID": epubBlockID,
                "audiobookID": audiobookID
            ]
        )
    }
}
