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
            anchorKind: AlignmentAnchorRecord.AnchorKind.point.rawValue,
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
            anchorKind: AlignmentAnchorRecord.AnchorKind.chapterStart.rawValue,
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
            anchorKind: AlignmentAnchorRecord.AnchorKind.chapterEnd.rawValue,
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

    /// Lightweight anchor representation that unifies real DB anchors with
    /// synthetic chapter-boundary anchors for interpolation sorting.
    private struct AnchorPoint {
        let sequenceIndex: Int
        let audioTime: TimeInterval
        let isVirtual: Bool
    }

    /// Recalculates all affected `timeline_item` rows in one transaction.
    ///
    /// Interpolation rules:
    /// 1. Locked anchors always take precedence
    /// 2. Blocks grouped by chapter get virtual boundary anchors at chapter
    ///    start/end, enabling proportional interpolation even without manual anchors
    /// 3. Blocks between two anchors (real or virtual) interpolate linearly by `sequence_index`
    /// 4. If either bracket is a virtual anchor → status = `estimated`;
    ///    only pure manual-anchor brackets → status = `interpolated`
    /// 5. Blocks without chapter data fall back to flat global interpolation
    /// 6. Hidden blocks become `alignment_status = omitted`, `is_enabled = false`
    func recalculateTimeline() throws {
        let blocks = try blockDAO.blocks(for: audiobookID)
        let anchors = try anchorDAO.anchors(for: audiobookID)
        let chapters = try chapterDAO.chapters(for: audiobookID)

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

        // Group blocks by chapter for chapter-aware interpolation.
        let blocksByChapter: [Int: [EPubBlockRecord]] = {
            var dict: [Int: [EPubBlockRecord]] = [:]
            for block in blocks where block.chapterIndex != nil {
                dict[block.chapterIndex!, default: []].append(block)
            }
            return dict
        }()

        let sortedChapters = chapters.sorted { $0.sortOrder < $1.sortOrder }
        var processedBlockIDs = Set<String>()

        // ── Chapter-aware interpolation ──────────────────────────
        for (chapterIndex, chapterBlocks) in blocksByChapter {
            guard chapterIndex < sortedChapters.count else { continue }
            let chapter = sortedChapters[chapterIndex]
            let sortedBlocks = chapterBlocks.sorted { $0.sequenceIndex < $1.sequenceIndex }
            guard let firstBlock = sortedBlocks.first,
                  let lastBlock = sortedBlocks.last else { continue }

            // Build virtual boundary anchors.
            let virtualStart = AnchorPoint(
                sequenceIndex: firstBlock.sequenceIndex - 1,
                audioTime: chapter.startSeconds,
                isVirtual: true
            )
            let virtualEnd = AnchorPoint(
                sequenceIndex: lastBlock.sequenceIndex + 1,
                audioTime: chapter.endSeconds,
                isVirtual: true
            )

            // Collect manual anchors belonging to blocks in this chapter.
            let manualAnchorPoints: [AnchorPoint] = anchors.compactMap { anchor in
                guard let blk = blockByID[anchor.epubBlockID],
                      blk.chapterIndex == chapterIndex else { return nil }
                return AnchorPoint(
                    sequenceIndex: blk.sequenceIndex,
                    audioTime: anchor.audioTime,
                    isVirtual: false
                )
            }

            let allAnchors = (manualAnchorPoints + [virtualStart, virtualEnd])
                .sorted { $0.sequenceIndex < $1.sequenceIndex }

            guard allAnchors.count >= 2 else { continue }

            for block in sortedBlocks {
                if block.isHidden {
                    try timelineDAO.updateAlignment(
                        epubBlockID: block.id,
                        audiobookID: audiobookID,
                        audioStartTime: -1,
                        timestampSource: TimestampSource.none.rawValue,
                        alignmentStatus: AlignmentStatus.omitted.rawValue,
                        isEnabled: false
                    )
                    processedBlockIDs.insert(block.id)
                    continue
                }

                if let lockedTime = anchorTimeByBlockID[block.id] {
                    try timelineDAO.updateAlignment(
                        epubBlockID: block.id,
                        audiobookID: audiobookID,
                        audioStartTime: lockedTime,
                        timestampSource: TimestampSource.lockedAnchor.rawValue,
                        alignmentStatus: AlignmentStatus.lockedAnchor.rawValue,
                        isEnabled: true
                    )
                    processedBlockIDs.insert(block.id)
                    continue
                }

                // Find bracketing anchors in the merged list.
                let blockSeq = block.sequenceIndex
                var prev: AnchorPoint?
                var next: AnchorPoint?
                for anchor in allAnchors {
                    if anchor.sequenceIndex < blockSeq {
                        prev = anchor
                    } else if anchor.sequenceIndex > blockSeq, next == nil {
                        next = anchor
                    }
                }

                guard let prev, let next else {
                    // Outside the bounded range — leave unaligned.
                    try timelineDAO.updateAlignment(
                        epubBlockID: block.id,
                        audiobookID: audiobookID,
                        audioStartTime: -1,
                        timestampSource: TimestampSource.none.rawValue,
                        alignmentStatus: AlignmentStatus.unaligned.rawValue,
                        isEnabled: true
                    )
                    processedBlockIDs.insert(block.id)
                    continue
                }

                let prevSeq = Double(prev.sequenceIndex)
                let nextSeq = Double(next.sequenceIndex)
                let blockSeqD = Double(blockSeq)
                let fraction = (blockSeqD - prevSeq) / (nextSeq - prevSeq)
                let audioStart = prev.audioTime + fraction * (next.audioTime - prev.audioTime)

                // "Virtual boundary taints": if either bracket is virtual → estimated.
                let hasVirtualBoundary = prev.isVirtual || next.isVirtual
                let timestampSrc = hasVirtualBoundary
                    ? TimestampSource.estimated.rawValue
                    : TimestampSource.interpolated.rawValue
                let alignStatus = hasVirtualBoundary
                    ? AlignmentStatus.estimated.rawValue
                    : AlignmentStatus.interpolated.rawValue

                try timelineDAO.updateAlignment(
                    epubBlockID: block.id,
                    audiobookID: audiobookID,
                    audioStartTime: audioStart,
                    timestampSource: timestampSrc,
                    alignmentStatus: alignStatus,
                    isEnabled: true
                )
                processedBlockIDs.insert(block.id)
            }
        }

        // ── Legacy flat interpolation (blocks without chapter data) ──
        let anchoredBlocks = blocks.filter { anchorTimeByBlockID[$0.id] != nil }
            .sorted { $0.sequenceIndex < $1.sequenceIndex }

        for block in blocks where !processedBlockIDs.contains(block.id) {
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
            } else if anchoredBlocks.count >= 2,
                      let (prev, next) = findBracketingAnchors(
                          block: block,
                          anchoredBlocks: anchoredBlocks,
                          anchorTimes: anchorTimeByBlockID
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
                audioStart = -1
                timestampSrc = TimestampSource.none.rawValue
                alignStatus = AlignmentStatus.unaligned.rawValue
            }

            try timelineDAO.updateAlignment(
                epubBlockID: block.id,
                audiobookID: audiobookID,
                audioStartTime: audioStart,
                timestampSource: timestampSrc,
                alignmentStatus: alignStatus,
                isEnabled: !block.isHidden
            )
        }

        logger.info("Recalculated timeline for \(audiobookID): \(blocks.count) blocks, \(anchors.count) anchors, \(chapters.count) chapters")
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
