// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct KaraokeHighlightTransitionTests {
    @Test func firstHighlightClearsNothing() {
        #expect(KaraokeHighlightTransition.blockToClear(previous: nil, next: "A") == nil)
    }

    @Test func sameBlockNewWordClearsNothing() {
        // The active word moved to a new index within the same paragraph.
        #expect(KaraokeHighlightTransition.blockToClear(previous: "A", next: "A") == nil)
    }

    @Test func crossingParagraphClearsPrevious() {
        // The reported bug: A's last word must be cleared when playback enters B.
        #expect(KaraokeHighlightTransition.blockToClear(previous: "A", next: "B") == "A")
    }

    @Test func goingToNoActiveWordClearsPrevious() {
        #expect(KaraokeHighlightTransition.blockToClear(previous: "A", next: nil) == "A")
    }
}
