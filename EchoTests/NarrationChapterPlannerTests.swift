import Foundation
import Testing

@testable import Echo

@Suite struct NarrationChapterPlannerTests {

    private func block(id: String, chapter: Int?, text: String?, seq: Int) -> EPubBlockRecord {
        EPubBlockRecord(
            id: id, audiobookID: "b1", spineHref: "c.xhtml",
            spineIndex: 0, blockIndex: seq, sequenceIndex: seq,
            blockKind: "paragraph", text: text, htmlContent: nil, cardColor: nil,
            chapterThemeColor: nil, imagePath: nil, chapterIndex: chapter,
            isHidden: false, hiddenReason: nil, isFrontMatter: false,
            wordCount: nil, markers: nil, textFormats: nil,
            createdAt: nil, modifiedAt: nil)
    }

    @Test func groupsByChapterSortedSkippingNilAndTextlessChapters() {
        let blocks = [
            block(id: "a", chapter: 1, text: "one", seq: 5),
            block(id: "b", chapter: 0, text: "alpha", seq: 1),
            block(id: "c", chapter: 0, text: "beta", seq: 0),
            block(id: "d", chapter: nil, text: "front matter", seq: 2),  // no chapter → skipped
            block(id: "e", chapter: 2, text: nil, seq: 9),  // chapter 2 has…
            block(id: "f", chapter: 2, text: "", seq: 10),  // …no spoken text → skipped
        ]

        let plan = NarrationChapterPlanner.plan(from: blocks)

        // Chapters in ascending order; nil-chapter and text-less chapters dropped.
        #expect(plan.map(\.index) == [0, 1])
        // Display numbers are 1-based and contiguous over the surviving chapters.
        #expect(plan.map(\.displayNumber) == [1, 2])
        // Within a chapter, blocks are ordered by sequence index.
        #expect(plan[0].blocks.map(\.id) == ["c", "b"])
        #expect(plan[1].blocks.map(\.id) == ["a"])
    }

    /// The bug behind "chapter 4 is actually chapter 1": front matter occupies the
    /// low EPUB chapter indices, so the first *narratable* chapter sits at a high
    /// raw index. `displayNumber` must restart at 1 for it (while `index` keeps the
    /// raw value that keys the cache/track id), and skip the textless gap (index 4)
    /// without leaving a hole in the numbering.
    @Test func displayNumberIsContiguousDespiteFrontMatterAndGaps() {
        let blocks = [
            block(id: "fm0", chapter: 0, text: nil, seq: 0),  // cover (no text) → dropped
            block(id: "fm1", chapter: 1, text: "", seq: 1),  // copyright (empty) → dropped
            block(id: "fm2", chapter: 2, text: nil, seq: 2),  // toc (no text) → dropped
            block(id: "c3", chapter: 3, text: "Real chapter one.", seq: 3),
            block(id: "c4", chapter: 4, text: nil, seq: 4),  // image-only section → dropped
            block(id: "c5", chapter: 5, text: "Real chapter two.", seq: 5),
        ]

        let plan = NarrationChapterPlanner.plan(from: blocks)

        // Raw indices retained for identity; only the two text chapters survive.
        #expect(plan.map(\.index) == [3, 5])
        // …but the user sees Chapter 1 and Chapter 2, not "Chapter 4" / "Chapter 6".
        #expect(plan.map(\.displayNumber) == [1, 2])
    }

    @Test func emptyInputYieldsNoChapters() {
        #expect(NarrationChapterPlanner.plan(from: []).isEmpty)
    }

    @Test func resumeStartsAtChapterThenForwardOnly() {
        let plan = [0, 1, 2, 3].map {
            NarrationChapterPlanner.PlannedChapter(
                index: $0, displayNumber: $0 + 1,
                blocks: [block(id: "b\($0)", chapter: $0, text: "t", seq: 0)])
        }
        #expect(
            NarrationChapterPlanner.resume(plan, startingAtChapterIndex: 2).map(\.index) == [2, 3])
        // Unknown index → full plan from the start.
        #expect(
            NarrationChapterPlanner.resume(plan, startingAtChapterIndex: 99).map(\.index) == [
                0, 1, 2, 3,
            ])
    }

    /// `beforeResume` returns the earlier chapters in DESCENDING order so they can
    /// be rendered-then-prepended to land the queue ascending (§5.3 / Phase 4B).
    /// Together, `resume` ++ `beforeResume` cover the whole plan with no overlap.
    @Test func beforeResumeReturnsEarlierChaptersDescending() {
        let plan = [0, 1, 2, 3].map {
            NarrationChapterPlanner.PlannedChapter(
                index: $0, displayNumber: $0 + 1,
                blocks: [block(id: "b\($0)", chapter: $0, text: "t", seq: 0)])
        }
        // Resuming at 2: forward = [2,3], earlier (descending) = [1,0].
        #expect(
            NarrationChapterPlanner.beforeResume(plan, startingAtChapterIndex: 2).map(\.index)
                == [1, 0])
        // Forward ++ earlier covers every chapter exactly once.
        let forward = NarrationChapterPlanner.resume(plan, startingAtChapterIndex: 2).map(\.index)
        let earlier = NarrationChapterPlanner.beforeResume(plan, startingAtChapterIndex: 2).map(
            \.index)
        #expect(Set(forward + earlier) == Set([0, 1, 2, 3]))
        #expect(forward.count + earlier.count == 4)
        // Resuming at the first chapter → nothing earlier.
        #expect(NarrationChapterPlanner.beforeResume(plan, startingAtChapterIndex: 0).isEmpty)
        // Unknown index → nothing earlier (resume() already plays the full plan).
        #expect(NarrationChapterPlanner.beforeResume(plan, startingAtChapterIndex: 99).isEmpty)
    }
}
