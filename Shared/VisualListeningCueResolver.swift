// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum VisualListeningSyncPoint: String, CaseIterable, Codable, Sendable {
    case begin
    case midpoint
}

enum VisualListeningImageCueSource: String, Codable, Sendable {
    case explicitTimeline
    case derivedFromNearbyText
}

struct VisualListeningImageCue: Equatable, Identifiable, Sendable {
    var id: String { blockID }

    let blockID: String
    let imagePath: String
    let caption: String?
    let subtitleBlockID: String?
    let chapterIndex: Int?
    let sequenceIndex: Int
    let displayStartTime: TimeInterval
    let displayEndTime: TimeInterval
    let syncPoint: VisualListeningSyncPoint
    let source: VisualListeningImageCueSource
}

struct VisualListeningSubtitleCue: Equatable, Sendable {
    let blockID: String
    let text: String
    let activeWordIndex: Int?
    let alreadyHeardWordCount: Int
}

struct VisualListeningSnapshot: Equatable, Sendable {
    var imageCue: VisualListeningImageCue?
    var subtitleCue: VisualListeningSubtitleCue?
    var activeBlockID: String?

    static let empty = VisualListeningSnapshot(
        imageCue: nil,
        subtitleCue: nil,
        activeBlockID: nil
    )
}

enum VisualListeningCueResolver {
    static func snapshot(
        blocks: [EPubBlockRecord],
        timeline: [ReaderActiveBlockResolver.TimelineRow],
        words: [ReaderActiveBlockResolver.WordRow],
        time: TimeInterval,
        currentTrackSegmentKey: String?,
        currentTrackChapterIndices: Set<Int>?,
        syncPoint: VisualListeningSyncPoint
    ) -> VisualListeningSnapshot {
        let orderedBlocks = blocks.sorted { lhs, rhs in
            if lhs.sequenceIndex == rhs.sequenceIndex {
                return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
            }
            return lhs.sequenceIndex < rhs.sequenceIndex
        }
        let blocksByID = Dictionary(uniqueKeysWithValues: orderedBlocks.map { ($0.id, $0) })
        let activeBlockID = ReaderActiveBlockResolver.activeBlockID(
            in: timeline,
            time: time,
            currentTrackSegmentKey: currentTrackSegmentKey,
            currentTrackChapterIndices: currentTrackChapterIndices
        )
        let imageCue = activeImageCue(
            blocks: orderedBlocks,
            blocksByID: blocksByID,
            timeline: timeline,
            time: time,
            currentTrackSegmentKey: currentTrackSegmentKey,
            currentTrackChapterIndices: currentTrackChapterIndices,
            syncPoint: syncPoint
        )
        let subtitleCue = subtitleCue(
            blockID: activeBlockID,
            blocksByID: blocksByID,
            words: words,
            time: time
        ) ?? subtitleCue(
            blockID: imageCue?.subtitleBlockID,
            blocksByID: blocksByID,
            words: words,
            time: time
        )

        return VisualListeningSnapshot(
            imageCue: imageCue,
            subtitleCue: subtitleCue,
            activeBlockID: activeBlockID
        )
    }

    private static func activeImageCue(
        blocks: [EPubBlockRecord],
        blocksByID: [String: EPubBlockRecord],
        timeline: [ReaderActiveBlockResolver.TimelineRow],
        time: TimeInterval,
        currentTrackSegmentKey: String?,
        currentTrackChapterIndices: Set<Int>?,
        syncPoint: VisualListeningSyncPoint
    ) -> VisualListeningImageCue? {
        imageCues(
            blocks: blocks,
            blocksByID: blocksByID,
            timeline: timeline,
            currentTrackSegmentKey: currentTrackSegmentKey,
            currentTrackChapterIndices: currentTrackChapterIndices,
            syncPoint: syncPoint
        )
        .filter { time >= $0.displayStartTime && time < $0.displayEndTime }
        .max { lhs, rhs in
            if lhs.sequenceIndex == rhs.sequenceIndex {
                return lhs.displayStartTime < rhs.displayStartTime
            }
            return lhs.sequenceIndex < rhs.sequenceIndex
        }
    }

    private static func imageCues(
        blocks: [EPubBlockRecord],
        blocksByID: [String: EPubBlockRecord],
        timeline: [ReaderActiveBlockResolver.TimelineRow],
        currentTrackSegmentKey: String?,
        currentTrackChapterIndices: Set<Int>?,
        syncPoint: VisualListeningSyncPoint
    ) -> [VisualListeningImageCue] {
        let scopedRows = timeline.filter {
            rowIsInScope(
                $0,
                currentTrackSegmentKey: currentTrackSegmentKey,
                currentTrackChapterIndices: currentTrackChapterIndices
            )
        }
        let imageBlocks = blocks.filter {
            !$0.isHidden
                && $0.blockKind == EPubBlockRecord.Kind.image.rawValue
                && ($0.imagePath?.isEmpty == false)
        }

        return imageBlocks.compactMap { block in
            if let explicit = scopedRows.first(where: { $0.blockID == block.id && $0.end > $0.start }) {
                return makeImageCue(
                    block: block,
                    imagePath: block.imagePath ?? "",
                    subtitleBlockID: block.text?.isEmpty == false ? block.id : nil,
                    displayStart: explicit.start,
                    displayEnd: explicit.end,
                    syncPoint: syncPoint,
                    source: .explicitTimeline
                )
            }

            guard
                let reference = referenceRow(
                    for: block,
                    rows: scopedRows,
                    blocksByID: blocksByID
                )
            else { return nil }
            let window = displayWindow(
                referenceStart: reference.start,
                referenceEnd: reference.end,
                syncPoint: syncPoint
            )
            guard window.end > window.start else { return nil }
            return makeImageCue(
                block: block,
                imagePath: block.imagePath ?? "",
                subtitleBlockID: reference.blockID,
                displayStart: window.start,
                displayEnd: window.end,
                syncPoint: syncPoint,
                source: .derivedFromNearbyText
            )
        }
    }

    private static func referenceRow(
        for imageBlock: EPubBlockRecord,
        rows: [ReaderActiveBlockResolver.TimelineRow],
        blocksByID: [String: EPubBlockRecord]
    ) -> ReaderActiveBlockResolver.TimelineRow? {
        let candidateRows = rows
            .filter { row in
                guard row.end > row.start,
                    row.chapterIndex == imageBlock.chapterIndex,
                    let block = blocksByID[row.blockID],
                    block.blockKind != EPubBlockRecord.Kind.image.rawValue,
                    block.text?.isEmpty == false
                else { return false }
                return true
            }
            .sorted { lhs, rhs in
                let lhsSequence = blocksByID[lhs.blockID]?.sequenceIndex ?? Int.max
                let rhsSequence = blocksByID[rhs.blockID]?.sequenceIndex ?? Int.max
                if lhsSequence == rhsSequence { return lhs.start < rhs.start }
                return lhsSequence < rhsSequence
            }

        if let following = candidateRows.first(where: {
            (blocksByID[$0.blockID]?.sequenceIndex ?? Int.max) >= imageBlock.sequenceIndex
        }) {
            return following
        }
        return candidateRows.last(where: {
            (blocksByID[$0.blockID]?.sequenceIndex ?? Int.min) < imageBlock.sequenceIndex
        })
    }

    private static func displayWindow(
        referenceStart: TimeInterval,
        referenceEnd: TimeInterval,
        syncPoint: VisualListeningSyncPoint
    ) -> (start: TimeInterval, end: TimeInterval) {
        switch syncPoint {
        case .begin:
            return (start: max(0, referenceStart), end: max(referenceStart, referenceEnd))
        case .midpoint:
            let duration = max(0, referenceEnd - referenceStart)
            let midpoint = referenceStart + duration / 2
            return (
                start: max(0, midpoint - duration),
                end: midpoint + duration
            )
        }
    }

    private static func makeImageCue(
        block: EPubBlockRecord,
        imagePath: String,
        subtitleBlockID: String?,
        displayStart: TimeInterval,
        displayEnd: TimeInterval,
        syncPoint: VisualListeningSyncPoint,
        source: VisualListeningImageCueSource
    ) -> VisualListeningImageCue {
        VisualListeningImageCue(
            blockID: block.id,
            imagePath: imagePath,
            caption: block.text,
            subtitleBlockID: subtitleBlockID,
            chapterIndex: block.chapterIndex,
            sequenceIndex: block.sequenceIndex,
            displayStartTime: displayStart,
            displayEndTime: displayEnd,
            syncPoint: syncPoint,
            source: source
        )
    }

    private static func subtitleCue(
        blockID: String?,
        blocksByID: [String: EPubBlockRecord],
        words: [ReaderActiveBlockResolver.WordRow],
        time: TimeInterval
    ) -> VisualListeningSubtitleCue? {
        guard let blockID,
            let block = blocksByID[blockID],
            let text = block.text,
            !text.isEmpty
        else { return nil }

        let activeWordIndex = ReaderActiveBlockResolver.activeWord(
            in: words,
            time: time,
            activeBlockID: blockID
        )
        let alreadyHeardWordCount = words.filter {
            $0.blockID == blockID && $0.end <= time
        }.count

        return VisualListeningSubtitleCue(
            blockID: blockID,
            text: text,
            activeWordIndex: activeWordIndex,
            alreadyHeardWordCount: alreadyHeardWordCount
        )
    }

    private static func rowIsInScope(
        _ row: ReaderActiveBlockResolver.TimelineRow,
        currentTrackSegmentKey: String?,
        currentTrackChapterIndices: Set<Int>?
    ) -> Bool {
        if let currentTrackSegmentKey {
            return row.segmentKey == currentTrackSegmentKey
        }

        guard let scope = currentTrackChapterIndices else { return true }
        if let chapterIndex = row.chapterIndex {
            return scope.contains(chapterIndex)
        }
        return scope.contains(0)
    }
}
