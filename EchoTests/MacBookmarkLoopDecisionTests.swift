// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// Unit tests for the pure A–B bookmark-loop decision used by the macOS
/// raw-AVPlayer model (MacPlayerModel). The logic lives in `EchoCore/Services/`
/// so it is reachable from this test target; the model wiring that calls it is
/// in the `Echo macOS` target and is exercised structurally (MacPlaybackWiringTests).
struct MacBookmarkLoopDecisionTests {

    // Three bookmarks → two loopable segments: [10,120) and [120,300).
    private let marks: [Double] = [10, 120, 300]

    @Test func fewerThanTwoBookmarksNeverLoops() {
        #expect(
            MacBookmarkLoopDecision.seekBackTarget(
                currentTime: 50, bookmarkTimes: [], speed: 1.0) == nil)
        #expect(
            MacBookmarkLoopDecision.seekBackTarget(
                currentTime: 50, bookmarkTimes: [10], speed: 1.0) == nil)
    }

    @Test func midSegmentKeepsPlaying() {
        // Comfortably inside the first segment, far from the next bookmark (120).
        #expect(
            MacBookmarkLoopDecision.seekBackTarget(
                currentTime: 50, bookmarkTimes: marks, speed: 1.0) == nil)
    }

    @Test func approachingNextBookmarkSeeksBackToSegmentStart() {
        // Within the 0.5s look-ahead of the second bookmark (120) → loop to 10 (+0.05).
        let target = MacBookmarkLoopDecision.seekBackTarget(
            currentTime: 119.8, bookmarkTimes: marks, speed: 1.0)
        #expect(target == 10.05)
    }

    @Test func fasterSpeedWidensLookAhead() {
        // At 3× the look-ahead is 0.9s, so 119.2 already triggers the loop-back.
        let atFast = MacBookmarkLoopDecision.seekBackTarget(
            currentTime: 119.2, bookmarkTimes: marks, speed: 3.0)
        #expect(atFast == 10.05)
        // …but at 1× (look-ahead 0.5s) the same position is still mid-segment.
        let atSlow = MacBookmarkLoopDecision.seekBackTarget(
            currentTime: 119.2, bookmarkTimes: marks, speed: 1.0)
        #expect(atSlow == nil)
    }

    @Test func secondSegmentLoopsToItsOwnStart() {
        // Inside [120,300), approaching 300 → loop back to 120 (+0.05).
        let target = MacBookmarkLoopDecision.seekBackTarget(
            currentTime: 299.7, bookmarkTimes: marks, speed: 1.0)
        #expect(target == 120.05)
    }

    @Test func beforeFirstBookmarkKeepsPlaying() {
        // No bookmark precedes the playhead → no segment yet.
        #expect(
            MacBookmarkLoopDecision.seekBackTarget(
                currentTime: 5, bookmarkTimes: marks, speed: 1.0) == nil)
    }

    @Test func justPastLastBookmarkLoopsFinalSegment() {
        // Crossed the final bookmark (300) by < 1s → loop the last segment (→120).
        let target = MacBookmarkLoopDecision.seekBackTarget(
            currentTime: 300.4, bookmarkTimes: marks, speed: 1.0)
        #expect(target == 120.05)
    }

    @Test func wellPastLastBookmarkStopsLooping() {
        // More than 1s past the final bookmark → fall through, no loop.
        #expect(
            MacBookmarkLoopDecision.seekBackTarget(
                currentTime: 305, bookmarkTimes: marks, speed: 1.0) == nil)
    }

    @Test func nonFiniteTimeIsSafe() {
        #expect(
            MacBookmarkLoopDecision.seekBackTarget(
                currentTime: .nan, bookmarkTimes: marks, speed: 1.0) == nil)
    }
}
