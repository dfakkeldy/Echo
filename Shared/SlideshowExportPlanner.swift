// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// One audio track's contribution to the export timeline. `segmentKey` /
/// `chapterIndices` must carry the same scoping the live player derives for the
/// track (see `PlayerModel+VisualListeningScope`); the caller derives them so
/// this file stays free of EchoCore naming helpers and compiles for every
/// target that consumes `Shared/`.
nonisolated struct SlideshowTrackContext: Equatable, Sendable {
    let title: String
    let duration: TimeInterval
    let segmentKey: String?
    let chapterIndices: Set<Int>?
}

nonisolated enum SlideshowExportMode: String, Sendable {
    case karaoke
    case simple
}

nonisolated struct SlideshowFramePlan: Equatable, Sendable {
    let startTime: TimeInterval
    let duration: TimeInterval
    let visualContent: VisualListeningVisualContent?
    let caption: String?
    let subtitleText: String?
    let activeWordIndex: Int?
    let alreadyHeardWordCount: Int
}

/// `VisualListeningVisualContent` declares `Equatable` in
/// `VisualListeningCueResolver.swift`, whose synthesized `==` inherits this
/// module's default `@MainActor` isolation (`SWIFT_DEFAULT_ACTOR_ISOLATION =
/// MainActor`). This planner — and `SlideshowFramePlan` above — are
/// `nonisolated` (the export pipeline runs off-main), so they cannot call a
/// MainActor-isolated `==`. Providing the witness here explicitly (equivalent
/// to what would otherwise be synthesized) satisfies the existing
/// `Equatable` conformance without touching the resolver file.
extension VisualListeningVisualContent {
    nonisolated static func == (
        lhs: VisualListeningVisualContent, rhs: VisualListeningVisualContent
    ) -> Bool {
        switch (lhs, rhs) {
        case (.image(let lhsPath), .image(let rhsPath)):
            return lhsPath == rhsPath
        case (.code(let lhsText, let lhsLanguage), .code(let rhsText, let rhsLanguage)):
            return lhsText == rhsText && lhsLanguage == rhsLanguage
        // Exhaustive (no `default:`) so a future third case fails to compile
        // here rather than silently comparing equal instances as unequal.
        case (.image, _), (.code, _):
            return false
        }
    }
}

nonisolated struct SlideshowSRTCue: Equatable, Sendable {
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
}

nonisolated struct SlideshowExportPlan: Equatable, Sendable {
    let frames: [SlideshowFramePlan]
    let srtCues: [SlideshowSRTCue]
    let totalDuration: TimeInterval
}

/// Turns aligned book data into a deterministic whole-book slideshow plan.
/// Every visual decision is delegated to `VisualListeningCueResolver`, sampled
/// once per boundary event, so the export cannot drift from the live stage.
nonisolated enum SlideshowExportPlanner {
    /// Maximum characters per SRT cue (two standard 42-char subtitle lines).
    static let maxCueLength = 84

    static func plan(
        blocks: [EPubBlockRecord],
        timeline: [ReaderActiveBlockResolver.TimelineRow],
        words: [ReaderActiveBlockResolver.WordRow],
        tracks: [SlideshowTrackContext],
        mode: SlideshowExportMode,
        syncPoint: VisualListeningSyncPoint,
        range: Range<TimeInterval>? = nil
    ) -> SlideshowExportPlan {
        let orderedBlocks = blocks.sorted { lhs, rhs in
            if lhs.sequenceIndex == rhs.sequenceIndex {
                return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
            }
            return lhs.sequenceIndex < rhs.sequenceIndex
        }
        let blocksByID = Dictionary(uniqueKeysWithValues: orderedBlocks.map { ($0.id, $0) })

        var frames: [SlideshowFramePlan] = []
        var srtCues: [SlideshowSRTCue] = []
        var offset: TimeInterval = 0

        for track in tracks {
            let scopedRows: [ReaderActiveBlockResolver.TimelineRow] = timeline.compactMap {
                row -> ReaderActiveBlockResolver.TimelineRow? in
                guard
                    VisualListeningCueResolver.rowIsInScope(
                        row,
                        currentTrackSegmentKey: track.segmentKey,
                        currentTrackChapterIndices: track.chapterIndices)
                else { return nil }

                let start = max(0, row.start)
                let end = min(track.duration, row.end)
                guard end > start else { return nil }
                return (
                    start: start,
                    end: end,
                    blockID: row.blockID,
                    chapterIndex: row.chapterIndex,
                    segmentKey: row.segmentKey
                )
            }
            let scopedBlockIDs = Set(scopedRows.map(\.blockID))
            let scopedWords: [ReaderActiveBlockResolver.WordRow] = words.compactMap {
                word -> ReaderActiveBlockResolver.WordRow? in
                guard scopedBlockIDs.contains(word.blockID) else { return nil }
                let start = min(max(0, word.start), track.duration)
                let end = min(max(0, word.end), track.duration)
                return (
                    start: start,
                    end: end,
                    blockID: word.blockID,
                    wordIndex: word.wordIndex
                )
            }
            let boundaries = trackBoundaries(
                orderedBlocks: orderedBlocks, blocksByID: blocksByID,
                timeline: scopedRows, scopedRows: scopedRows, words: scopedWords,
                track: track, mode: mode, syncPoint: syncPoint)

            for (start, end) in zip(boundaries, boundaries.dropFirst()) where end > start {
                let snapshot = VisualListeningCueResolver.snapshot(
                    blocks: orderedBlocks, timeline: scopedRows,
                    words: mode == .karaoke ? scopedWords : [],
                    time: start,
                    currentTrackSegmentKey: track.segmentKey,
                    currentTrackChapterIndices: track.chapterIndices,
                    syncPoint: syncPoint)
                let frame = SlideshowFramePlan(
                    startTime: offset + start,
                    duration: end - start,
                    visualContent: snapshot.visualCue?.content,
                    caption: snapshot.visualCue?.caption,
                    subtitleText: snapshot.subtitleCue?.text,
                    activeWordIndex: mode == .karaoke
                        ? snapshot.subtitleCue?.activeWordIndex : nil,
                    alreadyHeardWordCount: mode == .karaoke
                        ? (snapshot.subtitleCue?.alreadyHeardWordCount ?? 0) : 0)
                appendMerging(frame, to: &frames)
            }

            let textRows =
                scopedRows
                .filter { row in
                    row.end > row.start
                        && blocksByID[row.blockID]
                            .flatMap { VisualListeningCueResolver.subtitleText(for: $0) }?.isEmpty
                            == false
                }
                .sorted { $0.start < $1.start }
            for row in textRows {
                srtCues.append(
                    contentsOf: splitCues(
                        forRow: row, blocksByID: blocksByID, words: scopedWords, offset: offset))
            }

            offset += track.duration
        }

        let total = offset
        guard let range else {
            return SlideshowExportPlan(frames: frames, srtCues: srtCues, totalDuration: total)
        }
        return clamp(
            SlideshowExportPlan(frames: frames, srtCues: srtCues, totalDuration: total),
            to: normalizedRange(range, totalDuration: total))
    }

    // MARK: - Boundaries

    private static func trackBoundaries(
        orderedBlocks: [EPubBlockRecord],
        blocksByID: [String: EPubBlockRecord],
        timeline: [ReaderActiveBlockResolver.TimelineRow],
        scopedRows: [ReaderActiveBlockResolver.TimelineRow],
        words: [ReaderActiveBlockResolver.WordRow],
        track: SlideshowTrackContext,
        mode: SlideshowExportMode,
        syncPoint: VisualListeningSyncPoint
    ) -> [TimeInterval] {
        var times: Set<TimeInterval> = [0, track.duration]
        for row in scopedRows {
            times.insert(row.start)
            times.insert(row.end)
        }
        let cues = VisualListeningCueResolver.visualCues(
            blocks: orderedBlocks, blocksByID: blocksByID, timeline: timeline,
            currentTrackSegmentKey: track.segmentKey,
            currentTrackChapterIndices: track.chapterIndices,
            syncPoint: syncPoint)
        for cue in cues {
            times.insert(cue.displayStartTime)
            times.insert(cue.displayEndTime)
        }
        if mode == .karaoke {
            let scopedBlockIDs = Set(scopedRows.map(\.blockID))
            for word in words where scopedBlockIDs.contains(word.blockID) {
                times.insert(word.start)
                times.insert(word.end)
            }
        }
        return times.filter { $0 >= 0 && $0 <= track.duration }.sorted()
    }

    /// Appends a frame, extending the previous frame instead when nothing
    /// visible changed (turns dense boundary sampling into sparse output).
    private static func appendMerging(
        _ frame: SlideshowFramePlan, to frames: inout [SlideshowFramePlan]
    ) {
        if let last = frames.last,
            last.visualContent == frame.visualContent,
            last.caption == frame.caption,
            last.subtitleText == frame.subtitleText,
            last.activeWordIndex == frame.activeWordIndex,
            last.alreadyHeardWordCount == frame.alreadyHeardWordCount,
            abs(last.startTime + last.duration - frame.startTime) < 0.001
        {
            frames[frames.count - 1] = SlideshowFramePlan(
                startTime: last.startTime,
                duration: last.duration + frame.duration,
                visualContent: last.visualContent, caption: last.caption,
                subtitleText: last.subtitleText,
                activeWordIndex: last.activeWordIndex,
                alreadyHeardWordCount: last.alreadyHeardWordCount)
            return
        }
        frames.append(frame)
    }

    // MARK: - SRT

    /// Splits one timeline row's block text into cues of at most
    /// `maxCueLength` characters. Cue windows come from word timings when the
    /// block's sorted word rows match its display tokens 1:1 (the same
    /// positional mapping `VisualListeningCueResolver.subtitleCue` uses);
    /// otherwise the row window is divided proportionally by character count.
    private static func splitCues(
        forRow row: ReaderActiveBlockResolver.TimelineRow,
        blocksByID: [String: EPubBlockRecord],
        words: [ReaderActiveBlockResolver.WordRow],
        offset: TimeInterval
    ) -> [SlideshowSRTCue] {
        guard let block = blocksByID[row.blockID],
            let text = VisualListeningCueResolver.subtitleText(for: block),
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return [] }
        let tokenRanges = WordTokenizer.wordRanges(in: text)
        guard !tokenRanges.isEmpty else { return [] }

        // Greedily pack whole words into ≤ maxCueLength chunks.
        var chunks: [(tokens: Range<Int>, text: String)] = []
        var chunkStart = 0
        for index in tokenRanges.indices {
            let candidate = String(
                text[tokenRanges[chunkStart].lowerBound..<tokenRanges[index].upperBound])
            if candidate.count > maxCueLength, index > chunkStart {
                let chunkText = String(
                    text[tokenRanges[chunkStart].lowerBound..<tokenRanges[index - 1].upperBound])
                chunks.append((tokens: chunkStart..<index, text: chunkText))
                chunkStart = index
            }
        }
        let tailText = String(
            text[tokenRanges[chunkStart].lowerBound..<tokenRanges[tokenRanges.count - 1].upperBound]
        )
        chunks.append((tokens: chunkStart..<tokenRanges.count, text: tailText))
        chunks = chunks.flatMap { chunk in
            splitOversizedChunk(chunk)
        }

        let blockWords =
            words
            .filter { $0.blockID == row.blockID }
            .sorted { lhs, rhs in
                if lhs.start == rhs.start { return lhs.wordIndex < rhs.wordIndex }
                return lhs.start < rhs.start
            }
        let wordsMatchTokens = blockWords.count == tokenRanges.count

        var cues: [SlideshowSRTCue] = []
        var cursor = row.start
        let totalCharacters = chunks.reduce(0) { $0 + $1.text.count }
        for (index, chunk) in chunks.enumerated() {
            let end: TimeInterval
            if index == chunks.count - 1 {
                end = row.end
            } else if wordsMatchTokens, !chunk.tokens.isEmpty {
                end = min(row.end, blockWords[chunk.tokens.upperBound - 1].end)
            } else {
                let fraction = Double(chunk.text.count) / Double(max(1, totalCharacters))
                end = min(row.end, cursor + (row.end - row.start) * fraction)
            }
            cues.append(
                SlideshowSRTCue(
                    startTime: offset + cursor, endTime: offset + max(cursor, end),
                    text: chunk.text))
            cursor = max(cursor, end)
        }
        return cues
    }

    // MARK: - Range clamping

    /// Intersects an arbitrary valid request with the export's non-negative
    /// timeline. Clamping both endpoints before making the range keeps requests
    /// that sit completely before or after the plan from inverting it.
    private static func normalizedRange(
        _ requested: Range<TimeInterval>, totalDuration: TimeInterval
    ) -> Range<TimeInterval> {
        let lower = min(max(requested.lowerBound, 0), totalDuration)
        let upper = min(max(requested.upperBound, lower), totalDuration)
        return lower..<upper
    }

    /// A whitespace-delimited token can itself exceed the SRT ceiling (for
    /// example, a URL). Break those chunks at character boundaries, retaining
    /// the timing token only on the final fragment that completes it.
    private static func splitOversizedChunk(
        _ chunk: (tokens: Range<Int>, text: String)
    ) -> [(tokens: Range<Int>, text: String)] {
        guard chunk.text.count > maxCueLength else { return [chunk] }

        var fragments: [(tokens: Range<Int>, text: String)] = []
        var start = chunk.text.startIndex
        while start < chunk.text.endIndex {
            let end =
                chunk.text.index(
                    start, offsetBy: maxCueLength, limitedBy: chunk.text.endIndex)
                ?? chunk.text.endIndex
            let isFinalFragment = end == chunk.text.endIndex
            let tokens =
                isFinalFragment
                ? chunk.tokens
                : chunk.tokens.lowerBound..<chunk.tokens.lowerBound
            fragments.append((tokens: tokens, text: String(chunk.text[start..<end])))
            start = end
        }
        return fragments
    }

    private static func clamp(
        _ plan: SlideshowExportPlan, to range: Range<TimeInterval>
    ) -> SlideshowExportPlan {
        let frames = plan.frames.compactMap { frame -> SlideshowFramePlan? in
            let start = max(frame.startTime, range.lowerBound)
            let end = min(frame.startTime + frame.duration, range.upperBound)
            guard end > start else { return nil }
            return SlideshowFramePlan(
                startTime: start - range.lowerBound, duration: end - start,
                visualContent: frame.visualContent, caption: frame.caption,
                subtitleText: frame.subtitleText,
                activeWordIndex: frame.activeWordIndex,
                alreadyHeardWordCount: frame.alreadyHeardWordCount)
        }
        let cues = plan.srtCues.compactMap { cue -> SlideshowSRTCue? in
            let start = max(cue.startTime, range.lowerBound)
            let end = min(cue.endTime, range.upperBound)
            guard end > start else { return nil }
            return SlideshowSRTCue(
                startTime: start - range.lowerBound, endTime: end - range.lowerBound,
                text: cue.text)
        }
        return SlideshowExportPlan(
            frames: frames, srtCues: cues,
            totalDuration: range.upperBound - range.lowerBound)
    }
}
