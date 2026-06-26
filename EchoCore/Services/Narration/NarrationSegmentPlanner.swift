// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Splits planned narration chapters into ordered render segments. The first
/// segment of a book is intentionally small so playback can start quickly once
/// the renderer learns to queue segment files; later segments are larger to keep
/// file/track counts bounded.
enum NarrationSegmentPlanner {
    struct PlannedSegment: Equatable {
        let chapterIndex: Int
        let chapterDisplayNumber: Int
        let chapterTitle: String
        let segmentIndex: Int
        let blocks: [EPubBlockRecord]

        init(
            chapterIndex: Int,
            chapterDisplayNumber: Int,
            segmentIndex: Int,
            blocks: [EPubBlockRecord],
            chapterTitle: String? = nil
        ) {
            self.chapterIndex = chapterIndex
            self.chapterDisplayNumber = chapterDisplayNumber
            self.chapterTitle = chapterTitle
                ?? NarrationChapterPlanner.title(
                    displayNumber: chapterDisplayNumber, blocks: blocks)
            self.segmentIndex = segmentIndex
            self.blocks = blocks
        }
    }

    private static let charsPerSecond = 14.0
    private static let firstSegmentTargetSeconds = 8.0
    private static let laterSegmentTargetSeconds = 50.0

    static func plan(_ chapters: [NarrationChapterPlanner.PlannedChapter])
        -> [PlannedSegment]
    {
        chapters.enumerated().flatMap { offset, chapter in
            segments(for: chapter, isFirstChapterOfBook: offset == 0)
        }
    }

    /// Segments at or after `resumeIndex`, ascending. Resume intentionally starts
    /// at the first segment of the chapter, preserving the existing chapter-level
    /// resume contract while the player moves from chapter files to segment files.
    static func resume(_ segments: [PlannedSegment], startingAtChapterIndex resumeIndex: Int)
        -> [PlannedSegment]
    {
        guard let pos = segments.firstIndex(where: { $0.chapterIndex == resumeIndex }) else {
            return segments
        }
        return Array(segments[pos...])
    }

    /// Segments before `resumeIndex`, in the order they should be rendered when
    /// each result is prepended at queue index 0. This is the reverse of the
    /// forward order (chapter descending, segment descending within each chapter)
    /// so repeated prepends land the queue back in normal ascending playback order.
    static func beforeResume(
        _ segments: [PlannedSegment],
        startingAtChapterIndex resumeIndex: Int
    ) -> [PlannedSegment] {
        guard let pos = segments.firstIndex(where: { $0.chapterIndex == resumeIndex }) else {
            return []
        }
        return Array(segments[..<pos].reversed())
    }

    static func segments(
        for chapter: NarrationChapterPlanner.PlannedChapter,
        isFirstChapterOfBook: Bool
    ) -> [PlannedSegment] {
        var result: [PlannedSegment] = []
        var currentBlocks: [EPubBlockRecord] = []
        var currentSeconds = 0.0
        var segmentIndex = 0

        func targetSeconds() -> Double {
            isFirstChapterOfBook && segmentIndex == 0
                ? firstSegmentTargetSeconds
                : laterSegmentTargetSeconds
        }

        func flush() {
            guard !currentBlocks.isEmpty else { return }
            result.append(
                PlannedSegment(
                    chapterIndex: chapter.index,
                    chapterDisplayNumber: chapter.displayNumber,
                    segmentIndex: segmentIndex,
                    blocks: currentBlocks,
                    chapterTitle: chapter.title
                ))
            segmentIndex += 1
            currentBlocks = []
            currentSeconds = 0
        }

        for block in chapter.blocks {
            currentBlocks.append(block)
            currentSeconds += Self.estimatedSeconds(for: block)
            if currentSeconds >= targetSeconds() {
                flush()
            }
        }
        flush()
        return result
    }

    private static func estimatedSeconds(for block: EPubBlockRecord) -> Double {
        max(1.0, Double((block.text ?? "").count) / charsPerSecond)
    }
}
