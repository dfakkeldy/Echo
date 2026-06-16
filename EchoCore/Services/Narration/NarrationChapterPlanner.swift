// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Turns a book's EPUB blocks into the ordered list of chapters that on-device
/// narration should render and play, one rendered file (and pipeline track) per
/// chapter. Pure logic so it can be unit-tested without the TTS engine.
enum NarrationChapterPlanner {

    /// One narratable chapter: its chapter index plus the blocks to synthesize,
    /// in reading (sequence) order.
    struct PlannedChapter: Equatable {
        let index: Int
        let blocks: [EPubBlockRecord]
    }

    /// Groups `blocks` by chapter index, ascending. Blocks with no chapter index
    /// (front matter that wasn't mapped) are dropped, as are chapters with no
    /// spoken text (image-only or empty), so narration never renders silent
    /// chapters. Within a chapter, blocks are returned in sequence order.
    static func plan(from blocks: [EPubBlockRecord]) -> [PlannedChapter] {
        let grouped = Dictionary(grouping: blocks.filter { $0.chapterIndex != nil }) {
            $0.chapterIndex!
        }
        return grouped.keys.sorted().compactMap { index in
            let chapterBlocks = grouped[index]!.sorted { $0.sequenceIndex < $1.sequenceIndex }
            guard chapterBlocks.contains(where: { ($0.text?.isEmpty == false) }) else { return nil }
            return PlannedChapter(index: index, blocks: chapterBlocks)
        }
    }

    /// Reorders a plan to begin at `resumeIndex` (forward-only). Earlier chapters
    /// are dropped from the queue — going back before the resume point re-narrates
    /// from scratch, which is acceptable for v1. Unknown index → unchanged plan.
    static func resume(_ chapters: [PlannedChapter], startingAtChapterIndex resumeIndex: Int)
        -> [PlannedChapter]
    {
        guard let pos = chapters.firstIndex(where: { $0.index == resumeIndex }) else {
            return chapters
        }
        return Array(chapters[pos...])
    }
}
