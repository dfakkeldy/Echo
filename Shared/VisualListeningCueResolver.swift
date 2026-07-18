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

/// What the visual stage shows for a cue: a figure image or a code listing.
enum VisualListeningVisualContent: Equatable, Sendable {
    case image(path: String)
    case code(text: String, language: String?)
}

struct VisualListeningVisualCue: Equatable, Identifiable, Sendable {
    var id: String { blockID }

    let blockID: String
    let content: VisualListeningVisualContent
    let caption: String?
    let subtitleBlockID: String?
    let chapterIndex: Int?
    let sequenceIndex: Int
    let displayStartTime: TimeInterval
    let displayEndTime: TimeInterval
    let syncPoint: VisualListeningSyncPoint
    let source: VisualListeningImageCueSource

    /// Image path when the content is an image; nil for code. Kept so
    /// image-loading call sites stay simple (`visualCue?.imagePath`).
    var imagePath: String? {
        if case .image(let path) = content { return path }
        return nil
    }
}

struct VisualListeningSubtitleCue: Equatable, Sendable {
    let blockID: String
    let text: String
    /// Display-token ordinal for the subtitle string, not the raw persisted
    /// `word_timing.word_index` value. Generated timings may use sparse source
    /// indices, while the stage renderer walks visible tokens contiguously.
    let activeWordIndex: Int?
    let alreadyHeardWordCount: Int
}

struct VisualListeningSnapshot: Equatable, Sendable {
    var visualCue: VisualListeningVisualCue?
    var subtitleCue: VisualListeningSubtitleCue?
    var activeBlockID: String?

    static let empty = VisualListeningSnapshot(
        visualCue: nil,
        subtitleCue: nil,
        activeBlockID: nil
    )
}

nonisolated enum VisualListeningCueResolver {
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
        let visualCue = activeVisualCue(
            blocks: orderedBlocks,
            blocksByID: blocksByID,
            timeline: timeline,
            time: time,
            currentTrackSegmentKey: currentTrackSegmentKey,
            currentTrackChapterIndices: currentTrackChapterIndices,
            syncPoint: syncPoint
        )
        let subtitleCue =
            subtitleCue(
                blockID: activeBlockID,
                blocksByID: blocksByID,
                words: words,
                time: time
            )
            ?? subtitleCue(
                blockID: visualCue?.subtitleBlockID,
                blocksByID: blocksByID,
                words: words,
                time: time
            )

        return VisualListeningSnapshot(
            visualCue: visualCue,
            subtitleCue: subtitleCue,
            activeBlockID: activeBlockID
        )
    }

    private static func activeVisualCue(
        blocks: [EPubBlockRecord],
        blocksByID: [String: EPubBlockRecord],
        timeline: [ReaderActiveBlockResolver.TimelineRow],
        time: TimeInterval,
        currentTrackSegmentKey: String?,
        currentTrackChapterIndices: Set<Int>?,
        syncPoint: VisualListeningSyncPoint
    ) -> VisualListeningVisualCue? {
        visualCues(
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

    private static func visualCues(
        blocks: [EPubBlockRecord],
        blocksByID: [String: EPubBlockRecord],
        timeline: [ReaderActiveBlockResolver.TimelineRow],
        currentTrackSegmentKey: String?,
        currentTrackChapterIndices: Set<Int>?,
        syncPoint: VisualListeningSyncPoint
    ) -> [VisualListeningVisualCue] {
        let scopedRows = timeline.filter {
            rowIsInScope(
                $0,
                currentTrackSegmentKey: currentTrackSegmentKey,
                currentTrackChapterIndices: currentTrackChapterIndices
            )
        }
        let visualBlocks = blocks.filter { block in
            guard !block.isHidden else { return false }
            switch EPubBlockRecord.Kind(rawValue: block.blockKind) {
            case .image: return block.imagePath?.isEmpty == false
            case .code: return block.text?.isEmpty == false
            default: return false
            }
        }

        return visualBlocks.compactMap { block in
            if let explicit = scopedRows.first(where: {
                $0.blockID == block.id && $0.end > $0.start
            }) {
                let subtitleBlockID =
                    block.text?.isEmpty == false
                    ? block.id
                    : referenceRow(for: block, rows: scopedRows, blocksByID: blocksByID)?.blockID

                return makeVisualCue(
                    block: block,
                    subtitleBlockID: subtitleBlockID,
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
            return makeVisualCue(
                block: block,
                subtitleBlockID: reference.blockID,
                displayStart: window.start,
                displayEnd: window.end,
                syncPoint: syncPoint,
                source: .derivedFromNearbyText
            )
        }
    }

    private static func referenceRow(
        for visualBlock: EPubBlockRecord,
        rows: [ReaderActiveBlockResolver.TimelineRow],
        blocksByID: [String: EPubBlockRecord]
    ) -> ReaderActiveBlockResolver.TimelineRow? {
        let candidateRows =
            rows
            .filter { row in
                guard row.end > row.start,
                    row.chapterIndex == visualBlock.chapterIndex,
                    let block = blocksByID[row.blockID],
                    {
                        let kind = EPubBlockRecord.Kind(rawValue: block.blockKind)
                        return kind != .image && kind != .code
                    }(),
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
            (blocksByID[$0.blockID]?.sequenceIndex ?? Int.max) >= visualBlock.sequenceIndex
        }) {
            return following
        }
        return candidateRows.last(where: {
            (blocksByID[$0.blockID]?.sequenceIndex ?? Int.min) < visualBlock.sequenceIndex
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

    private static func makeVisualCue(
        block: EPubBlockRecord,
        subtitleBlockID: String?,
        displayStart: TimeInterval,
        displayEnd: TimeInterval,
        syncPoint: VisualListeningSyncPoint,
        source: VisualListeningImageCueSource
    ) -> VisualListeningVisualCue? {
        let content: VisualListeningVisualContent
        let caption: String?
        switch EPubBlockRecord.Kind(rawValue: block.blockKind) {
        case .image:
            guard let path = block.imagePath, !path.isEmpty else { return nil }
            content = .image(path: path)
            caption = block.text
        case .code:
            guard let code = block.text, !code.isEmpty else { return nil }
            content = .code(text: code, language: block.codeLanguage)
            caption = block.narrationText
        default:
            return nil
        }
        return VisualListeningVisualCue(
            blockID: block.id,
            content: content,
            caption: caption,
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
            let block = blocksByID[blockID]
        else { return nil }

        let text: String
        if EPubBlockRecord.Kind(rawValue: block.blockKind) == .code {
            // Keep this shared-target fallback in sync with NarrationCodeBlockCue.fallback.
            let fallback = "Code listing."
            text =
                block.narrationText?.trimmingCharacters(in: .whitespacesAndNewlines)
                    .isEmpty == false
                ? (block.narrationText ?? fallback)
                : fallback
        } else if let blockText = block.text, !blockText.isEmpty {
            text = blockText
        } else {
            return nil
        }
        let blockWords =
            words
            .filter { $0.blockID == blockID }
            .sorted { lhs, rhs in
                if lhs.start == rhs.start {
                    if lhs.end == rhs.end { return lhs.wordIndex < rhs.wordIndex }
                    return lhs.end < rhs.end
                }
                return lhs.start < rhs.start
            }
        let activeWordIndex = blockWords.firstIndex { word in
            time >= word.start && time < word.end
        }
        let alreadyHeardWordCount = blockWords.filter { $0.end <= time }.count

        return VisualListeningSubtitleCue(
            blockID: blockID,
            text: text,
            activeWordIndex: activeWordIndex,
            alreadyHeardWordCount: alreadyHeardWordCount
        )
    }

    static func rowIsInScope(
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
