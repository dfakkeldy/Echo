// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct NarrationRenderPlanTests {
    private func block(
        id: String,
        text: String?,
        kind: String = "paragraph",
        index: Int
    ) -> EPubBlockRecord {
        EPubBlockRecord(
            id: id, audiobookID: "book", spineHref: "c.xhtml",
            spineIndex: 0, blockIndex: index, sequenceIndex: index,
            blockKind: kind, text: text, htmlContent: nil,
            cardColor: nil, chapterThemeColor: nil, imagePath: nil,
            chapterIndex: 0, isHidden: false, hiddenReason: nil,
            isFrontMatter: false, wordCount: nil, markers: nil,
            textFormats: nil, createdAt: nil, modifiedAt: nil)
    }

    @Test func plansSpeechBlocksWithNormalizedOverrideText() {
        let blocks = [
            block(id: "b0", text: "Deploy Kubernetes — now.", index: 0)
        ]
        let overrides = PronunciationOverrides(entries: ["Kubernetes": "kuːbərˈnɛtɪs"])

        let plan = NarrationRenderPlanner.make(blocks: blocks, overrides: overrides, maxChars: 350)

        #expect(plan.blocks.count == 1)
        #expect(plan.blocks[0].blockID == "b0")
        #expect(plan.blocks[0].speechSegments == ["Deploy [Kubernetes](/kuːbərˈnɛtɪs/), now."])
        #expect(plan.blocks[0].trailingSilence == nil)
    }

    @Test func decorativeBlockBecomesSectionBreakSilenceOnly() {
        let blocks = [
            block(id: "b0", text: "Before.", index: 0),
            block(id: "b1", text: "* * *", index: 1),
            block(id: "b2", text: "After.", index: 2)
        ]

        let plan = NarrationRenderPlanner.make(
            blocks: blocks,
            overrides: PronunciationOverrides(entries: [:]),
            maxChars: 350)

        #expect(plan.blocks.map(\.blockID) == ["b0", "b1", "b2"])
        #expect(plan.blocks[0].speechSegments == ["Before."])
        #expect(plan.blocks[0].trailingSilence == nil)
        #expect(plan.blocks[1].speechSegments.isEmpty)
        #expect(plan.blocks[1].trailingSilence == .sectionBreak)
        #expect(plan.blocks[2].speechSegments == ["After."])
    }

    @Test func finalSpeakableBlockHasNoTrailingParagraphPause() {
        let blocks = [
            block(id: "b0", text: "Before.", index: 0),
            block(id: "b1", text: "After.", index: 1)
        ]

        let plan = NarrationRenderPlanner.make(
            blocks: blocks,
            overrides: PronunciationOverrides(entries: [:]),
            maxChars: 350)

        #expect(plan.blocks[0].trailingSilence == .paragraph)
        #expect(plan.blocks[1].trailingSilence == nil)
    }

    @Test func headingGetsLongerPauseThanParagraph() {
        let blocks = [
            block(id: "h", text: "Chapter One", kind: "heading", index: 0),
            block(id: "p", text: "The first paragraph.", index: 1)
        ]

        let plan = NarrationRenderPlanner.make(
            blocks: blocks,
            overrides: PronunciationOverrides(entries: [:]),
            maxChars: 350)

        #expect(plan.blocks[0].trailingSilence == .heading)
        #expect(plan.blocks[1].trailingSilence == nil)
    }
}
