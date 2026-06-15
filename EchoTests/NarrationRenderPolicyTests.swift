import Testing

@testable import Echo

/// Covers the pure-policy decisions extracted from the narration render loop.
/// Tests the look-ahead backpressure, pause-awareness, at-gap deadlock
/// prevention, and book-switch guard without any SwiftUI or AVFoundation
/// dependencies.
@Suite struct NarrationRenderPolicyTests {

    // MARK: - Offset zero (first chapter)

    @Test("Chapter 0 always renders regardless of index, playback, or gap state")
    func offsetZeroAlwaysRenders() {
        // Playing, well within lookAhead, not awaiting — should render.
        #expect(
            NarrationRenderPolicy.shouldPauseRender(
                offset: 0, currentPlaybackIndex: 0, lookAhead: 2,
                isPlaying: true, isAwaitingChapter: false) == false)

        // Current index far ahead of offset? Offset 0 still renders
        // (the player might have seeked, but chapter 0 must exist first).
        #expect(
            NarrationRenderPolicy.shouldPauseRender(
                offset: 0, currentPlaybackIndex: 99, lookAhead: 2,
                isPlaying: true, isAwaitingChapter: false) == false)

        // Paused and awaiting? Still renders.
        #expect(
            NarrationRenderPolicy.shouldPauseRender(
                offset: 0, currentPlaybackIndex: 0, lookAhead: 2,
                isPlaying: false, isAwaitingChapter: true) == false)
    }

    // MARK: - Look-ahead backpressure

    @Test("Render pauses when the current chapter is more than lookAhead behind")
    func lookAheadBackpressure() {
        // currentIndex = 1, lookAhead = 2 → chapters up to index 3 can
        // render (1 + 2 = 3). Chapter 4 should be blocked.
        #expect(
            NarrationRenderPolicy.shouldPauseRender(
                offset: 4, currentPlaybackIndex: 1, lookAhead: 2,
                isPlaying: true, isAwaitingChapter: false) == true)

        // Chapter 3 is at the edge of the lookAhead window → should render.
        #expect(
            NarrationRenderPolicy.shouldPauseRender(
                offset: 3, currentPlaybackIndex: 1, lookAhead: 2,
                isPlaying: true, isAwaitingChapter: false) == false)

        // Chapter 2 is within the lookAhead window → should render.
        #expect(
            NarrationRenderPolicy.shouldPauseRender(
                offset: 2, currentPlaybackIndex: 1, lookAhead: 2,
                isPlaying: true, isAwaitingChapter: false) == false)
    }

    @Test("Look-ahead backpressure with single-chapter window")
    func tightLookAhead() {
        // lookAhead = 1: only chapter (currentIndex + 1) can render.
        #expect(
            NarrationRenderPolicy.shouldPauseRender(
                offset: 1, currentPlaybackIndex: 0, lookAhead: 1,
                isPlaying: true, isAwaitingChapter: false) == false)

        #expect(
            NarrationRenderPolicy.shouldPauseRender(
                offset: 3, currentPlaybackIndex: 0, lookAhead: 1,
                isPlaying: true, isAwaitingChapter: false) == true)
    }

    // MARK: - Pause awareness

    @Test("Render pauses when the user paused and the player isn't awaiting a chapter")
    func pauseAware() {
        // Paused, not at queue end → pause render to avoid unbounded buffering.
        #expect(
            NarrationRenderPolicy.shouldPauseRender(
                offset: 2, currentPlaybackIndex: 0, lookAhead: 2,
                isPlaying: false, isAwaitingChapter: false) == true)

        // Playing → should render.
        #expect(
            NarrationRenderPolicy.shouldPauseRender(
                offset: 2, currentPlaybackIndex: 0, lookAhead: 2,
                isPlaying: true, isAwaitingChapter: false) == false)
    }

    // MARK: - At-gap deadlock prevention

    @Test("Render does NOT pause when the player is awaiting this chapter (at-gap)")
    func atGapDeadlockPrevention() {
        // The player auto-paused at the queue end waiting for this very
        // chapter — if we also paused rendering, they'd deadlock forever.
        #expect(
            NarrationRenderPolicy.shouldPauseRender(
                offset: 2, currentPlaybackIndex: 1, lookAhead: 2,
                isPlaying: false, isAwaitingChapter: true) == false)

        // Backpressure applies even when awaiting? The look-ahead check
        // comes first — if we're past the window, we still pause even
        // when awaiting (the player shouldn't be awaiting a chapter that
        // far ahead, but the guard prevents runaway rendering).
        #expect(
            NarrationRenderPolicy.shouldPauseRender(
                offset: 5, currentPlaybackIndex: 1, lookAhead: 2,
                isPlaying: false, isAwaitingChapter: true) == true)
    }

    // MARK: - Book-switch guard

    @Test("Book switch detected when folder URL differs from render-start audiobook ID")
    func bookSwitchDetection() {
        let startedID = "file:///Books/ThePragmaticProgrammer/"

        #expect(
            NarrationRenderPolicy.bookWasSwitched(
                currentFolderURL: "file:///Books/AliceInWonderland/",
                audiobookID: startedID) == true)

        #expect(
            NarrationRenderPolicy.bookWasSwitched(
                currentFolderURL: nil,
                audiobookID: startedID) == true)

        #expect(
            NarrationRenderPolicy.bookWasSwitched(
                currentFolderURL: startedID,
                audiobookID: startedID) == false)
    }
}
