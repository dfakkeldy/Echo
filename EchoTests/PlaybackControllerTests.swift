// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
@Suite struct PlaybackControllerTests {

    /// Any pause — user, remote/lock-screen, audio-session interruption,
    /// output-route disconnect, sleep timer — must cancel a pending narration
    /// at-gap auto-resume so the render loop does not fight the user.
    @Test func pauseClearsAwaitingNarrationChapter() {
        let c = PlaybackController()
        c.state.awaitingNarrationChapter = true

        c.pause()

        #expect(c.state.awaitingNarrationChapter == false)
    }

    /// Regression guard for the reorder footgun: the narration gap branch in
    /// nextTrack() must set awaitingNarrationChapter AFTER calling pause()
    /// (because pause() now clears it). If someone reverts to set-before-pause,
    /// the flag is wiped by pause() and this test's awaiting==true assertion
    /// fails — and on-device playback would stall forever at the gap.
    @Test func gapBranchSetsFlagAfterPause() {
        let c = PlaybackController()
        // Single-track narration queue at the last index so:
        //   - chapters.count < 2 skips nextChapter()
        //   - findNextEnabledTrackIndex returns nil (no enabled track after idx 0)
        //   - narrationRenderInFlight == true takes the gap branch (not the
        //     firstEnabled fallback, which is only reached when the flag is false)
        c.state.tracks = [Track(url: URL(string: "file:///tmp/ch0.m4a")!, title: "Chapter 1")]
        c.state.currentIndex = 0
        c.state.chapters = []
        c.state.narrationRenderInFlight = true

        c.nextTrack()

        // Flag survived pause() (set-AFTER-pause ordering intact)...
        #expect(c.state.awaitingNarrationChapter == true)
        // ...and the gap path did pause playback.
        #expect(c.state.isPlaying == false)
    }

    @Test func endOfBookDoesNotWrapToStart() {
        // Last chapter of a single-track book: nextChapter() must stay put, not
        // auto-restart the book from chapter 0 (§5.2). Previously it fell through
        // to `firstEnabled` and reloaded index 0 with autoplay.
        let c = PlaybackController()
        c.state.tracks = [Track(url: URL(string: "file:///tmp/book.m4b")!, title: "Book")]
        c.state.currentIndex = 0
        c.state.chapters = [
            Chapter(index: 0, title: "One", startSeconds: 0, endSeconds: 10),
            Chapter(index: 1, title: "Two", startSeconds: 10, endSeconds: 20),
        ]
        c.state.currentChapterIndex = 1
        // isMultiM4B is a computed get-only property; a single track with no
        // aggregated chapters is already non-aggregated.
        var loaded: Int?
        c.coordinator_loadTrack = { idx, _ in loaded = idx }

        c.nextChapter()

        #expect(loaded == nil)
    }

    @Test func findNextEnabledTrackIndexDoesNotTrapPastEnd() {
        let c = PlaybackController()
        let t = Track(url: URL(string: "file:///tmp/a.m4a")!, title: "A")
        // currentIndex past the last valid index must return nil, not trap.
        #expect(c.findNextEnabledTrackIndex(in: [t], currentIndex: 1) == nil)
    }

    @Test func forwardSkipTargetDoesNotCollapseToZeroWhenDurationUnknown() {
        // Unknown duration (briefly nil right after a track load) must not clamp
        // the target to 0 (which seeked to the track start).
        #expect(
            PlaybackController.forwardSkipTarget(current: 120, amount: 30, duration: nil) == 150)
        #expect(
            PlaybackController.forwardSkipTarget(current: 120, amount: 30, duration: 600) == 150)
        #expect(
            PlaybackController.forwardSkipTarget(current: 590, amount: 30, duration: 600) == 600)
    }

    @Test func cycleSkipsBookmarkLoopWhenUnavailable() {
        let c = PlaybackController()
        c.loopMode = .chapter
        c.coordinator_canBookmarkLoop = { false }

        c.cycleLoopMode()

        #expect(c.loopMode == .off)
    }

    @Test func cycleEntersBookmarkLoopWhenAvailable() {
        let c = PlaybackController()
        c.loopMode = .chapter
        c.coordinator_canBookmarkLoop = { true }

        c.cycleLoopMode()

        #expect(c.loopMode == .bookmark)
    }
}
