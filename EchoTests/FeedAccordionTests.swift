// SPDX-License-Identifier: GPL-3.0-or-later

import Testing

@testable import Echo

struct FeedAccordionTests {
    // MARK: toggled

    @Test func tappingClosedChapterOpensIt() {
        #expect(FeedAccordion.toggled(current: nil, tapped: 3) == 3)
    }

    @Test func tappingOpenChapterClosesIt() {
        #expect(FeedAccordion.toggled(current: 3, tapped: 3) == nil)
    }

    @Test func tappingDifferentChapterSwitchesOpenOne() {
        #expect(FeedAccordion.toggled(current: 3, tapped: 5) == 5)
    }

    // MARK: autoExpand

    @Test func autoExpandOpensNewlyPlayingChapter() {
        // Playing chapter went 2 -> 3; force chapter 3 open even though the user
        // had chapter 1 open.
        #expect(
            FeedAccordion.autoExpand(current: 1, playingChapterKey: 3, lastPlayingChapterKey: 2)
                == 3
        )
    }

    @Test func autoExpandLeavesUserChoiceWhenPlayingChapterUnchanged() {
        // Same playing chapter as last tick: respect a manual collapse/open.
        #expect(
            FeedAccordion.autoExpand(current: nil, playingChapterKey: 3, lastPlayingChapterKey: 3)
                == nil
        )
    }

    @Test func autoExpandIgnoresNilPlayingChapter() {
        #expect(
            FeedAccordion.autoExpand(current: 1, playingChapterKey: nil, lastPlayingChapterKey: 2)
                == 1
        )
    }
}
