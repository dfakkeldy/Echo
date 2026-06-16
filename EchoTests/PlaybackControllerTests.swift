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
}
