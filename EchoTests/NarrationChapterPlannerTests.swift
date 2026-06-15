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
        // Within a chapter, blocks are ordered by sequence index.
        #expect(plan[0].blocks.map(\.id) == ["c", "b"])
        #expect(plan[1].blocks.map(\.id) == ["a"])
    }

    @Test func emptyInputYieldsNoChapters() {
        #expect(NarrationChapterPlanner.plan(from: []).isEmpty)
    }

    @Test func resumeStartsAtChapterThenForwardOnly() {
        let plan = [0, 1, 2, 3].map {
            NarrationChapterPlanner.PlannedChapter(
                index: $0, blocks: [block(id: "b\($0)", chapter: $0, text: "t", seq: 0)])
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
                index: $0, blocks: [block(id: "b\($0)", chapter: $0, text: "t", seq: 0)])
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
