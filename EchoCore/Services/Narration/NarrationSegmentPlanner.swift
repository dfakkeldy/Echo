// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Splits planned narration chapters into ordered render segments. The first
/// segment of an ordinary book is intentionally small. Stable-key anthology
/// chapters each use the same small first-segment target so their file boundaries
/// remain stable when the anthology is reordered.
enum NarrationSegmentPlanner {
    struct PlannedSegment: Equatable, Sendable {
        let chapterIndex: Int
        let chapterDisplayNumber: Int
        let sourceChapterKey: String?
        let voice: VoiceID
        let chapterTitle: String
        let segmentIndex: Int
        let blocks: [EPubBlockRecord]

        init(
            chapterIndex: Int,
            chapterDisplayNumber: Int,
            sourceChapterKey: String?,
            voice: VoiceID,
            segmentIndex: Int,
            blocks: [EPubBlockRecord],
            chapterTitle: String? = nil
        ) {
            self.chapterIndex = chapterIndex
            self.chapterDisplayNumber = chapterDisplayNumber
            self.sourceChapterKey = sourceChapterKey
            self.voice = voice
            self.chapterTitle =
                chapterTitle
                ?? NarrationChapterPlanner.title(
                    displayNumber: chapterDisplayNumber, blocks: blocks)
            self.segmentIndex = segmentIndex
            self.blocks = blocks
        }

        /// Compatibility initializer for existing ordinary-book consumers that
        /// have not yet adopted the shared render-plan boundary.
        init(
            chapterIndex: Int,
            chapterDisplayNumber: Int,
            segmentIndex: Int,
            blocks: [EPubBlockRecord],
            chapterTitle: String? = nil
        ) {
            self.init(
                chapterIndex: chapterIndex,
                chapterDisplayNumber: chapterDisplayNumber,
                sourceChapterKey: nil,
                voice: VoiceCatalog.default.id,
                segmentIndex: segmentIndex,
                blocks: blocks,
                chapterTitle: chapterTitle)
        }
    }

    private static let charsPerSecond = 14.0
    private static let firstSegmentTargetSeconds = 8.0
    private static let laterSegmentTargetSeconds = 50.0

    static func plan(_ chapters: [NarrationChapterRenderPlan])
        -> [PlannedSegment]
    {
        chapters.enumerated().flatMap { offset, chapter in
            segments(for: chapter, isFirstChapterOfBook: offset == 0)
        }
    }

    /// Compatibility path for existing ordinary-book callers until they switch
    /// to the shared render-plan boundary. Anthology callers must resolve their
    /// manifest through `NarrationChapterRenderPlanner` first.
    static func plan(_ chapters: [NarrationChapterPlanner.PlannedChapter])
        -> [PlannedSegment]
    {
        plan(
            chapters.map {
                NarrationChapterRenderPlan(
                    chapterIndex: $0.index,
                    displayNumber: $0.displayNumber,
                    sourceChapterKey: nil,
                    title: $0.title,
                    blocks: $0.blocks,
                    voice: VoiceCatalog.default.id)
            })
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

    static func resume(
        _ segments: [PlannedSegment],
        startingAtSourceChapterKey sourceChapterKey: String
    ) -> [PlannedSegment] {
        guard let pos = segments.firstIndex(where: { $0.sourceChapterKey == sourceChapterKey })
        else {
            return segments
        }
        return Array(segments[pos...])
    }

    static func beforeResume(
        _ segments: [PlannedSegment],
        startingAtSourceChapterKey sourceChapterKey: String
    ) -> [PlannedSegment] {
        guard let pos = segments.firstIndex(where: { $0.sourceChapterKey == sourceChapterKey })
        else {
            return []
        }
        return Array(segments[..<pos].reversed())
    }

    static func segments(
        for chapter: NarrationChapterRenderPlan,
        isFirstChapterOfBook: Bool
    ) -> [PlannedSegment] {
        var result: [PlannedSegment] = []
        var currentBlocks: [EPubBlockRecord] = []
        var currentSeconds = 0.0
        var segmentIndex = 0
        let usesSmallFirstSegment = chapter.sourceChapterKey != nil || isFirstChapterOfBook

        func targetSeconds() -> Double {
            usesSmallFirstSegment && segmentIndex == 0
                ? firstSegmentTargetSeconds
                : laterSegmentTargetSeconds
        }

        func flush() {
            guard !currentBlocks.isEmpty else { return }
            result.append(
                PlannedSegment(
                    chapterIndex: chapter.chapterIndex,
                    chapterDisplayNumber: chapter.displayNumber,
                    sourceChapterKey: chapter.sourceChapterKey,
                    voice: chapter.voice,
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
        let spokenText = NarrationCodeBlockCue.spokenText(for: block) ?? block.text ?? ""
        return max(1.0, Double(spokenText.count) / charsPerSecond)
    }
}
