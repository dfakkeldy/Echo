// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct ReaderWordFollowScrollTests {
    @Test func compatibilityOverloadCentersAlreadyVisibleWord() throws {
        let target = try #require(
            ReaderWordFollowScroll.targetOffsetY(
                currentOffsetY: 100,
                viewportHeight: 500,
                contentHeight: 2_000,
                wordMinY: 240,
                wordMaxY: 270
            )
        )
        #expect(abs(target - 17) < 0.001)
    }

    @Test func compatibilityOverloadRejectsInvertedWordBounds() {
        let target = ReaderWordFollowScroll.targetOffsetY(
            currentOffsetY: 100,
            viewportHeight: 500,
            contentHeight: 2_000,
            wordMinY: 270,
            wordMaxY: 240
        )
        #expect(target == nil)
    }

    @Test func compatibilityOverloadSkipsShortContent() {
        let target = ReaderWordFollowScroll.targetOffsetY(
            currentOffsetY: 0,
            viewportHeight: 500,
            contentHeight: 400,
            wordMinY: 240,
            wordMaxY: 270
        )
        #expect(target == nil)
    }

    @Test func centersLineEvenWhenItIsAlreadyVisible() throws {
        let target = try #require(
            ReaderWordFollowScroll.targetOffsetY(
                currentOffsetY: 100,
                viewportHeight: 500,
                contentHeight: 2_000,
                targetRange: 240 ... 270,
                topInset: 64,
                bottomInset: 120
            )
        )
        #expect(abs(target - 33) < 0.001)
    }

    @Test func repeatedWordOnSameRenderedLineDoesNotMoveAgain() {
        let target = ReaderWordFollowScroll.targetOffsetY(
            currentOffsetY: 33,
            viewportHeight: 500,
            contentHeight: 2_000,
            targetRange: 240 ... 270,
            topInset: 64,
            bottomInset: 120
        )
        #expect(target == nil)
    }

    @Test func clampsAtBothContentEdges() throws {
        let start = try #require(
            ReaderWordFollowScroll.targetOffsetY(
                currentOffsetY: 300,
                viewportHeight: 500,
                contentHeight: 2_000,
                targetRange: 5 ... 25,
                topInset: 64,
                bottomInset: 120
            )
        )
        let end = try #require(
            ReaderWordFollowScroll.targetOffsetY(
                currentOffsetY: 900,
                viewportHeight: 500,
                contentHeight: 1_600,
                targetRange: 1_560 ... 1_590,
                topInset: 64,
                bottomInset: 120
            )
        )
        #expect(start == -64)
        #expect(end == 1_220)
    }

    @Test func wordLineWinsOverParagraphFallback() {
        #expect(
            ReaderWordFollowScroll.preferredRange(
                wordLine: 420 ... 450,
                paragraph: 300 ... 800
            ) == (420 ... 450)
        )
        #expect(
            ReaderWordFollowScroll.preferredRange(
                wordLine: nil,
                paragraph: 300 ... 800
            ) == (300 ... 800)
        )
    }
}
