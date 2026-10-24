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
    /// When pacing held the figure past its own window, the time the hold
    /// began. From then on only the active block supplies a subtitle, so a
    /// silent gap never brings back the figure's earlier reference text.
    var holdStartTime: TimeInterval?

    /// Image path when the content is an image; nil for code. Kept so
    /// image-loading call sites stay simple (`visualCue?.imagePath`).
    nonisolated var imagePath: String? {
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
                blockID: fallbackSubtitleBlockID(for: visualCue, time: time),
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

    /// Snapshot from PRE-computed cues: skips the per-tick sort + dictionary
    /// rebuild + cue derivation. `preparedCues` must come from `visualCues(…)`
    /// with the same scope arguments; the ViewModel invalidates on scope change.
    static func snapshot(
        preparedCues: [VisualListeningVisualCue],
        blocksByID: [String: EPubBlockRecord],
        words: [ReaderActiveBlockResolver.WordRow],
        timeline: [ReaderActiveBlockResolver.TimelineRow],
        time: TimeInterval,
        currentTrackSegmentKey: String?,
        currentTrackChapterIndices: Set<Int>?
    ) -> VisualListeningSnapshot {
        let activeBlockID = ReaderActiveBlockResolver.activeBlockID(
            in: timeline, time: time,
            currentTrackSegmentKey: currentTrackSegmentKey,
            currentTrackChapterIndices: currentTrackChapterIndices)
        let visualCue =
            preparedCues
            .filter { time >= $0.displayStartTime && time < $0.displayEndTime }
            .max { lhs, rhs in
                if lhs.sequenceIndex == rhs.sequenceIndex {
                    return lhs.displayStartTime < rhs.displayStartTime
                }
                return lhs.sequenceIndex < rhs.sequenceIndex
            }
        let subtitle =
            subtitleCue(blockID: activeBlockID, blocksByID: blocksByID, words: words, time: time)
            ?? subtitleCue(
                blockID: fallbackSubtitleBlockID(for: visualCue, time: time),
                blocksByID: blocksByID, words: words, time: time)
        return VisualListeningSnapshot(
            visualCue: visualCue, subtitleCue: subtitle, activeBlockID: activeBlockID)
    }

    private static func fallbackSubtitleBlockID(
        for cue: VisualListeningVisualCue?, time: TimeInterval
    ) -> String? {
        guard let cue else { return nil }
        if let holdStartTime = cue.holdStartTime, time >= holdStartTime { return nil }
        return cue.subtitleBlockID
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

    static func visualCues(
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

        let rawCues: [VisualListeningVisualCue] = visualBlocks.compactMap { block in
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
        return pacedCues(rawCues, rows: scopedRows)
    }

    /// Shortest time a figure stays up before a following derived figure may
    /// replace it. Explicit (spoken caption) cues are never delayed.
    static let minimumFigureDwell: TimeInterval = 3

    /// Paces raw cues per chapter so each figure stays on stage until the next
    /// one starts: derived figures that share one reference window split it
    /// in reading order, a derived figure waits up to `minimumFigureDwell`
    /// after the previous figure (sharing the room when the next figure or
    /// chapter end is closer), and every window extends to the next figure's
    /// start or, for the chapter's last figure, to the end of the chapter's
    /// spoken rows. Ends never move earlier, so overlap resolution (highest
    /// `sequenceIndex` wins) is unchanged.
    private static func pacedCues(
        _ cues: [VisualListeningVisualCue],
        rows: [ReaderActiveBlockResolver.TimelineRow]
    ) -> [VisualListeningVisualCue] {
        var chapterEnds: [Int?: TimeInterval] = [:]
        for row in rows where row.end > row.start {
            chapterEnds[row.chapterIndex] = max(chapterEnds[row.chapterIndex] ?? row.end, row.end)
        }

        var paced: [VisualListeningVisualCue] = []
        paced.reserveCapacity(cues.count)
        for (chapter, chapterCues) in Dictionary(grouping: cues, by: \.chapterIndex) {
            let ordered = chapterCues.sorted { lhs, rhs in
                if lhs.sequenceIndex == rhs.sequenceIndex {
                    return lhs.blockID.localizedStandardCompare(rhs.blockID) == .orderedAscending
                }
                return lhs.sequenceIndex < rhs.sequenceIndex
            }
            let chapterEnd =
                chapterEnds[chapter] ?? ordered.map(\.displayEndTime).max() ?? 0
            var starts = ordered.map(\.displayStartTime)

            // Consecutive derived figures with an identical window (no text
            // between them) split that window evenly instead of stacking.
            var groupStart = 0
            while groupStart < ordered.count {
                let first = ordered[groupStart]
                var groupEnd = groupStart + 1
                if first.source == .derivedFromNearbyText {
                    while groupEnd < ordered.count,
                        ordered[groupEnd].source == .derivedFromNearbyText,
                        ordered[groupEnd].displayStartTime == first.displayStartTime,
                        ordered[groupEnd].displayEndTime == first.displayEndTime
                    {
                        groupEnd += 1
                    }
                }
                let count = groupEnd - groupStart
                if count > 1 {
                    let slice = (first.displayEndTime - first.displayStartTime) / Double(count)
                    for offset in 1..<count {
                        starts[groupStart + offset] =
                            first.displayStartTime + slice * Double(offset)
                    }
                }
                groupStart = groupEnd
            }

            // Minimum dwell: a derived figure waits for the previous one. When
            // the next figure or the chapter end leaves too little room, the
            // two share what is left evenly instead of hiding either one.
            for index in ordered.indices.dropFirst()
            where ordered[index].source == .derivedFromNearbyText {
                var bound = chapterEnd
                if index + 1 < ordered.count, starts[index + 1] > starts[index] {
                    bound = min(bound, starts[index + 1])
                }
                let previous = starts[index - 1]
                let desired = previous + min(minimumFigureDwell, (bound - previous) / 2)
                starts[index] = max(starts[index], desired)
            }

            for (index, cue) in ordered.enumerated() {
                let start = starts[index]
                let nextStart = starts[(index + 1)...].first { $0 > start }
                let end = max(cue.displayEndTime, nextStart ?? chapterEnd)
                guard end > start else { continue }
                paced.append(
                    VisualListeningVisualCue(
                        blockID: cue.blockID,
                        content: cue.content,
                        caption: cue.caption,
                        subtitleBlockID: cue.subtitleBlockID,
                        chapterIndex: cue.chapterIndex,
                        sequenceIndex: cue.sequenceIndex,
                        displayStartTime: start,
                        displayEndTime: end,
                        syncPoint: cue.syncPoint,
                        source: cue.source,
                        holdStartTime: end > cue.displayEndTime ? cue.displayEndTime : nil
                    ))
            }
        }
        return paced.sorted { lhs, rhs in
            if lhs.sequenceIndex == rhs.sequenceIndex {
                return lhs.blockID.localizedStandardCompare(rhs.blockID) == .orderedAscending
            }
            return lhs.sequenceIndex < rhs.sequenceIndex
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

    static func subtitleCue(
        blockID: String?,
        blocksByID: [String: EPubBlockRecord],
        words: [ReaderActiveBlockResolver.WordRow],
        time: TimeInterval
    ) -> VisualListeningSubtitleCue? {
        guard let blockID,
            let block = blocksByID[blockID]
        else { return nil }

        guard let text = subtitleText(for: block) else { return nil }
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

    /// Text that may safely appear in subtitle surfaces. Code blocks expose
    /// their short narration cue, never the raw listing stored in `text`.
    static func subtitleText(for block: EPubBlockRecord) -> String? {
        if EPubBlockRecord.Kind(rawValue: block.blockKind) == .code {
            // Keep this shared-target fallback in sync with NarrationCodeBlockCue.fallback.
            let fallback = "Code listing."
            return block.narrationText?.trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false
                ? (block.narrationText ?? fallback)
                : fallback
        }
        guard let text = block.text, !text.isEmpty else { return nil }
        return text
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
