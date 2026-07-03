// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct ReaderWordFollowScrollTests {
    @Test func returnsNilWhenWordIsInsideReadableBand() {
        let target = ReaderWordFollowScroll.targetOffsetY(
            currentOffsetY: 100,
            viewportHeight: 500,
            contentHeight: 2_000,
            wordMinY: 240,
            wordMaxY: 270
        )

        #expect(target == nil)
    }

    @Test func scrollsDownWhenWordFallsBelowReadableBand() throws {
        let target = try #require(
            ReaderWordFollowScroll.targetOffsetY(
                currentOffsetY: 100,
                viewportHeight: 500,
                contentHeight: 2_000,
                wordMinY: 820,
                wordMaxY: 850
            ))

        #expect(abs(target - 585) < 0.001)
    }

    @Test func scrollsUpWhenWordFallsAboveReadableBand() throws {
        let target = try #require(
            ReaderWordFollowScroll.targetOffsetY(
                currentOffsetY: 800,
                viewportHeight: 500,
                contentHeight: 2_000,
                wordMinY: 760,
                wordMaxY: 790
            ))

        #expect(target < 800)
    }

    @Test func clampsToContentEnd() throws {
        let target = try #require(
            ReaderWordFollowScroll.targetOffsetY(
                currentOffsetY: 900,
                viewportHeight: 500,
                contentHeight: 1_600,
                wordMinY: 1_560,
                wordMaxY: 1_590
            ))

        #expect(target == 1_100)
    }
}
