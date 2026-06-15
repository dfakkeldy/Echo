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

    /// The chapters at or after `resumeIndex`, ascending — the part that renders
    /// and plays first on resume. Unknown index → the unchanged plan (play from
    /// the start). This is the *forward* set; `beforeResume` returns the rest so
    /// the full book stays in the queue.
    static func resume(_ chapters: [PlannedChapter], startingAtChapterIndex resumeIndex: Int)
        -> [PlannedChapter]
    {
        guard let pos = chapters.firstIndex(where: { $0.index == resumeIndex }) else {
            return chapters
        }
        return Array(chapters[pos...])
    }

    /// The chapters *before* `resumeIndex`, in **descending** order — rendered
    /// after the forward set and prepended to the queue so reopening a book keeps
    /// the FULL chapter list, not just the resume point onward (§5.3 / finish-plan
    /// Phase 4B), without a cold re-render of the whole book before playback can
    /// start. Empty when resuming at the first chapter or when `resumeIndex` is
    /// unknown. Descending so each rendered chapter can be cheaply prepended at
    /// index 0 and still land the queue in ascending chapter order.
    static func beforeResume(_ chapters: [PlannedChapter], startingAtChapterIndex resumeIndex: Int)
        -> [PlannedChapter]
    {
        guard let pos = chapters.firstIndex(where: { $0.index == resumeIndex }) else {
            return []
        }
        return Array(chapters[..<pos].reversed())
    }
}
