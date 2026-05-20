import Foundation
import os.log

/// Replaces timeline materialization embedded in PlayerModel and
/// TimelineIngestionFactory. Accepts all available data sources and
/// produces a complete, ordered [TimelineItem] array for the feed.
///
/// Ordering rules:
/// 1. EPUB blocks sort by sequence_index (structural order).
/// 2. Chapters sort by startSeconds.
/// 3. Bookmarks/cards sort by timestamp.
/// 4. All items merged: timestamped first, then un-timestamped EPUB by sequence.
struct TimelineIngestionService {
    private let db: DatabaseService
    private let logger = Logger(subsystem: "com.orbitaudiobooks", category: "TimelineIngestion")

    init(database: DatabaseService) {
        self.db = database
    }

    func ingest(
        audiobookID: String,
        chapters: [Chapter],
        epubBlocks: [EpubBlockRecord],
        anchors: [AlignmentAnchorRecord],
        bookmarks: [Bookmark],
        flashcards: [Flashcard],
        plainTranscript: [TranscriptionSegment]?,
        enhancedTranscript: [EnhancedTranscriptionSegment]?
    ) throws -> [TimelineItem] {
        var items: [TimelineItem] = []
        var seq = 0

        // 1. Chapter markers
        for chapter in chapters where chapter.isEnabled {
            let item = TimelineItem(
                id: "chapterMarker-\(audiobookID)-\(chapter.index)",
                audiobookID: audiobookID,
                itemType: .chapterMarker,
                title: chapter.title ?? "Chapter \(chapter.index + 1)",
                subtitle: nil,
                textPayload: nil,
                imagePath: nil,
                audioStartTime: chapter.startSeconds,
                audioEndTime: chapter.endSeconds,
                epubSequenceIndex: seq,
                granularityLevel: .chapter,
                playlistPosition: nil,
                isEnabled: true,
                sourceTable: "chapter",
                sourceRowid: String(chapter.index),
                metadataJSON: nil,
                createdAt: nil,
                modifiedAt: nil,
                epubBlockID: nil,
                timestampSource: "chapterMetadata",
                alignmentStatus: "estimated",
                alignmentConfidence: 1.0
            )
            items.append(item)
            seq += 1
        }

        // 2. EPUB text/image blocks
        for block in epubBlocks.sorted(by: { $0.sequenceIndex < $1.sequenceIndex }) {
            let hasAnchor = anchors.contains { $0.epubBlockID == block.id }
            let (audioStart, audioEnd, timestampSource, alignmentStatus, confidence): (TimeInterval, TimeInterval?, String, String, Double?) = {
                if let anchor = anchors.first(where: { $0.epubBlockID == block.id }) {
                    return (anchor.audioTime, anchor.audioEndTime, "lockedAnchor", "lockedAnchor", 1.0)
                }
                if block.isHidden {
                    return (-1, nil, "none", "omitted", nil)
                }
                // Estimate from chapter boundaries if available
                if let chapterIdx = block.chapterIndex,
                   chapterIdx < chapters.count {
                    let ch = chapters[chapterIdx]
                    let chapterDuration = ch.endSeconds - ch.startSeconds
                    let blockCount = epubBlocks.filter { $0.chapterIndex == chapterIdx && !$0.isHidden }.count
                    if blockCount > 0 {
                        let blockPos = epubBlocks.filter { $0.chapterIndex == chapterIdx && !$0.isHidden && $0.sequenceIndex < block.sequenceIndex }.count
                        let estimatedTime = ch.startSeconds + (chapterDuration * Double(blockPos) / Double(blockCount))
                        return (estimatedTime, nil, "estimated", "estimated", 0.5)
                    }
                }
                return (-1, nil, "none", "unaligned", nil)
            }()

            let itemType: TimelineItemType = block.blockKind == "image" ? .imageAsset : .textSegment
            let isEnabled = !block.isHidden

            let item = TimelineItem(
                id: "epubBlock-\(block.id)",
                audiobookID: audiobookID,
                itemType: itemType,
                title: block.text ?? (block.blockKind == "image" ? "Image" : ""),
                subtitle: block.blockKind == "image" ? "EPUB Image" : nil,
                textPayload: block.blockKind != "image" ? block.text : nil,
                imagePath: block.imagePath,
                audioStartTime: audioStart,
                audioEndTime: audioEnd,
                epubSequenceIndex: block.sequenceIndex,
                granularityLevel: block.blockKind == "heading" ? .chapter : .paragraph,
                playlistPosition: nil,
                isEnabled: isEnabled,
                sourceTable: "epub_block",
                sourceRowid: block.id,
                metadataJSON: nil,
                createdAt: nil,
                modifiedAt: nil,
                epubBlockID: block.id,
                timestampSource: timestampSource,
                alignmentStatus: alignmentStatus,
                alignmentConfidence: confidence
            )
            items.append(item)
            seq += 1
        }

        // 3. Bookmarks
        for bookmark in bookmarks where bookmark.isEnabled {
            let item = TimelineItem(
                id: "bookmark-\(bookmark.id.uuidString)",
                audiobookID: audiobookID,
                itemType: .bookmark,
                title: bookmark.title,
                subtitle: bookmark.note,
                textPayload: nil,
                imagePath: bookmark.bookmarkImageFileName,
                audioStartTime: bookmark.timestamp,
                audioEndTime: nil,
                epubSequenceIndex: nil,
                granularityLevel: .chapter,
                playlistPosition: nil,
                isEnabled: true,
                sourceTable: "bookmark",
                sourceRowid: bookmark.id.uuidString,
                metadataJSON: nil,
                createdAt: nil,
                modifiedAt: nil,
                epubBlockID: nil,
                timestampSource: "userBookmark",
                alignmentStatus: "lockedAnchor",
                alignmentConfidence: 1.0
            )
            items.append(item)
            seq += 1
        }

        // 4. Flashcards (Anki cards)
        for card in flashcards {
            let item = TimelineItem(
                id: "flashcard-\(card.id)",
                audiobookID: audiobookID,
                itemType: .ankiCard,
                title: card.frontText,
                subtitle: card.backText,
                textPayload: nil,
                imagePath: nil,
                audioStartTime: card.mediaTimestamp,
                audioEndTime: nil,
                epubSequenceIndex: nil,
                granularityLevel: .chapter,
                playlistPosition: nil,
                isEnabled: true,
                sourceTable: "flashcard",
                sourceRowid: card.id,
                metadataJSON: nil,
                createdAt: nil,
                modifiedAt: nil,
                epubBlockID: nil,
                timestampSource: "userCard",
                alignmentStatus: "lockedAnchor",
                alignmentConfidence: 1.0
            )
            items.append(item)
            seq += 1
        }

        // 5. Enhanced transcript segments (Whisper + EPUB alignment)
        if let enhanced = enhancedTranscript {
            for segment in enhanced {
                let item = TimelineItem(
                    id: "enhanced-\(audiobookID)-\(segment.startTime ?? 0)-\(segment.endTime ?? 0)",
                    audiobookID: audiobookID,
                    itemType: .textSegment,
                    title: segment.text,
                    subtitle: nil,
                    textPayload: segment.text,
                    imagePath: nil,
                    audioStartTime: segment.startTime ?? -1,
                    audioEndTime: segment.endTime,
                    epubSequenceIndex: nil,
                    granularityLevel: .sentence,
                    playlistPosition: nil,
                    isEnabled: true,
                    sourceTable: "transcription_segment",
                    sourceRowid: segment.id,
                    metadataJSON: encodeMarkers(segment.markers),
                    createdAt: nil,
                    modifiedAt: nil,
                    epubBlockID: nil,
                    timestampSource: segment.startTime != nil ? "transcript" : "none",
                    alignmentStatus: segment.startTime != nil ? "estimated" : "unaligned",
                    alignmentConfidence: nil
                )
                items.append(item)
                seq += 1
            }
        } else if let plain = plainTranscript {
            for segment in plain {
                let item = TimelineItem(
                    id: "transcript-\(audiobookID)-\(segment.startTime)-\(segment.endTime)",
                    audiobookID: audiobookID,
                    itemType: .textSegment,
                    title: segment.text,
                    subtitle: nil,
                    textPayload: segment.text,
                    imagePath: nil,
                    audioStartTime: segment.startTime,
                    audioEndTime: segment.endTime,
                    epubSequenceIndex: nil,
                    granularityLevel: .sentence,
                    playlistPosition: nil,
                    isEnabled: true,
                    sourceTable: "transcription_segment",
                    sourceRowid: segment.id,
                    metadataJSON: nil,
                    createdAt: nil,
                    modifiedAt: nil,
                    epubBlockID: nil,
                    timestampSource: "transcript",
                    alignmentStatus: "estimated",
                    alignmentConfidence: nil
                )
                items.append(item)
                seq += 1
            }
        }

        // Sort: timestamped items first by audioStartTime, untimestamped by
        // epubSequenceIndex. Hidden blocks at the end.
        items.sort { a, b in
            let aTimestamped = a.isTimestamped
            let bTimestamped = b.isTimestamped
            if aTimestamped && bTimestamped {
                return a.audioStartTime < b.audioStartTime
            }
            if aTimestamped { return true }
            if bTimestamped { return false }
            // Both untimestamped: sort by epub sequence
            let aSeq = a.epubSequenceIndex ?? Int.max
            let bSeq = b.epubSequenceIndex ?? Int.max
            return aSeq < bSeq
        }

        // Persist to DB
        let timelineDAO = TimelineDAO(db: db.writer)
        try timelineDAO.deleteAll(for: audiobookID)
        try timelineDAO.ingest(items)

        logger.info("Ingested \(items.count) timeline items for \(audiobookID)")

        // Notify observers
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .timelineItemsIngested,
                object: nil,
                userInfo: ["audiobookID": audiobookID]
            )
        }

        return items
    }

    private func encodeMarkers(_ markers: [SyncMarker]?) -> String? {
        guard let markers, !markers.isEmpty else { return nil }
        let encodable = markers.map {
            ["type": $0.type.rawValue, "payload": $0.payload, "epubCharOffset": $0.epubCharOffset]
        }
        if let data = try? JSONSerialization.data(withJSONObject: encodable),
           let json = String(data: data, encoding: .utf8) {
            return json
        }
        return nil
    }
}
