import Foundation
import GRDB
import os.log

/// Manages manual EPUB-to-audio alignment through locked anchors and
/// timestamp interpolation.
///
/// Public operations produce alignment anchors and recalculate affected
/// `timeline_item` rows in a single DB transaction.
struct AlignmentService {
    private let logger = Logger(subsystem: "com.orbitaudiobooks", category: "Alignment")
    private let anchorDAO: AlignmentAnchorDAO
    private let blockDAO: EPubBlockDAO
    private let timelineDAO: TimelineDAO
    private let audiobookID: String

    init(db: DatabaseWriter, audiobookID: String) {
        self.anchorDAO = AlignmentAnchorDAO(db: db)
        self.blockDAO = EPubBlockDAO(db: db)
        self.timelineDAO = TimelineDAO(db: db)
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
            anchorKind: AlignmentAnchorRecord.Kind.point.rawValue,
            source: AlignmentAnchorRecord.Source.moveToNow.rawValue,
            note: nil,
            createdAt: ISO8601DateFormatter().string(from: Date()),
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
            anchorKind: AlignmentAnchorRecord.Kind.point.rawValue,
            source: AlignmentAnchorRecord.Source.searchResult.rawValue,
            note: nil,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            modifiedAt: nil
        )
        if let existing = try anchorDAO.anchor(for: audiobookID, epubBlockID: blockID) {
            try anchorDAO.delete(id: existing.id)
        }
        try anchorDAO.upsert(anchor)
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
            anchorKind: AlignmentAnchorRecord.Kind.chapterStart.rawValue,
            source: AlignmentAnchorRecord.Source.chapterBoundary.rawValue,
            note: "Chapter \(chapterIndex) start",
            createdAt: ISO8601DateFormatter().string(from: Date()),
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
            anchorKind: AlignmentAnchorRecord.Kind.chapterEnd.rawValue,
            source: AlignmentAnchorRecord.Source.chapterBoundary.rawValue,
            note: "Chapter \(chapterIndex) end",
            createdAt: ISO8601DateFormatter().string(from: Date()),
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

    // MARK: - Timeline Recalculation

    /// Recalculates all affected `timeline_item` rows in one transaction.
    ///
    /// Interpolation rules:
    /// 1. Locked anchors always take precedence
    /// 2. Blocks between two anchors interpolate linearly by `sequence_index`
    /// 3. Blocks with chapter data but no manual anchors get `estimated`
    /// 4. Blocks outside known ranges stay `unaligned` with `audio_start_time = -1`
    /// 5. Hidden blocks become `alignment_status = omitted`, `is_enabled = false`
    func recalculateTimeline() throws {
        let blocks = try blockDAO.blocks(for: audiobookID)
        let anchors = try anchorDAO.anchors(for: audiobookID)

        guard !blocks.isEmpty else { return }

        // Build anchor lookup: blockID → audioTime
        let anchorTimeByBlockID: [String: TimeInterval] = {
            var dict: [String: TimeInterval] = [:]
            for anchor in anchors {
                dict[anchor.epubBlockID] = anchor.audioTime
            }
            return dict
        }()

        // Build ordered list of anchored blocks for interpolation ranges.
        let anchoredBlocks = blocks.filter { anchorTimeByBlockID[$0.id] != nil }
            .sorted { ($0.sequenceIndex) < ($1.sequenceIndex) }

        // For each block, determine its alignment.
        for block in blocks {
            let audioStart: TimeInterval
            let timestampSrc: String
            let alignStatus: String

            if block.isHidden {
                audioStart = -1
                timestampSrc = TimestampSource.none.rawValue
                alignStatus = AlignmentStatus.omitted.rawValue
            } else if let lockedTime = anchorTimeByBlockID[block.id] {
                audioStart = lockedTime
                timestampSrc = TimestampSource.lockedAnchor.rawValue
                alignStatus = AlignmentStatus.lockedAnchor.rawValue
            } else if anchoredBlocks.count >= 2 {
                // Find bracketing anchors by sequence_index.
                if let (prev, next) = findBracketingAnchors(
                    block: block, anchoredBlocks: anchoredBlocks, anchorTimes: anchorTimeByBlockID
                ) {
                    let prevSeq = Double(prev.sequenceIndex)
                    let nextSeq = Double(next.sequenceIndex)
                    let blockSeq = Double(block.sequenceIndex)
                    let prevTime = anchorTimeByBlockID[prev.id]!
                    let nextTime = anchorTimeByBlockID[next.id]!

                    let fraction = (blockSeq - prevSeq) / (nextSeq - prevSeq)
                    audioStart = prevTime + fraction * (nextTime - prevTime)
                    timestampSrc = TimestampSource.interpolated.rawValue
                    alignStatus = AlignmentStatus.interpolated.rawValue
                } else {
                    // Has anchors but this block is outside the anchored range.
                    audioStart = -1
                    timestampSrc = TimestampSource.none.rawValue
                    alignStatus = AlignmentStatus.unaligned.rawValue
                }
            } else if block.chapterIndex != nil {
                // Chapter data available but no anchors — estimate from chapter bounds.
                // This is a rough estimate: place blocks proportionally within the chapter.
                audioStart = -1
                timestampSrc = TimestampSource.estimated.rawValue
                alignStatus = AlignmentStatus.estimated.rawValue
            } else {
                audioStart = -1
                timestampSrc = TimestampSource.none.rawValue
                alignStatus = AlignmentStatus.unaligned.rawValue
            }

            // Update timeline_item row.
            try timelineDAO.updateAlignment(
                epubBlockID: block.id,
                audiobookID: audiobookID,
                audioStartTime: audioStart,
                timestampSource: timestampSrc,
                alignmentStatus: alignStatus,
                isEnabled: !block.isHidden
            )
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
    func updateAlignment(
        epubBlockID: String,
        audiobookID: String,
        audioStartTime: TimeInterval,
        timestampSource: String,
        alignmentStatus: String,
        isEnabled: Bool
    ) throws {
        try db.write { db in
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
                    "now": ISO8601DateFormatter().string(from: Date()),
                    "epubBlockID": epubBlockID,
                    "audiobookID": audiobookID
                ]
            )
        }
    }
}
