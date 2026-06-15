import Foundation

/// Pure policy decisions for the narration render loop — no SwiftUI,
/// AVFoundation, or database dependencies. Unit-testable in isolation.
///
/// Extracted from the inline logic in `PlayerModel+Narration.swift` so the
/// look-ahead backpressure, pause-awareness, at-gap deadlock prevention,
/// and book-switch guard are testable without constructing a full `PlayerModel`.
enum NarrationRenderPolicy {

    /// Whether the render loop should wait before synthesising the next chapter.
    ///
    /// - Parameters:
    ///   - offset: Current chapter offset in the planned list (0 = first).
    ///   - currentPlaybackIndex: The player's current track index.
    ///   - lookAhead: Maximum number of chapters to render ahead of playback.
    ///   - isPlaying: Whether the player is currently playing.
    ///   - isAwaitingChapter: Whether playback auto-paused at the queue end
    ///     waiting for *this* chapter — never block in that case, or render
    ///     and playback would deadlock.
    /// - Returns: `true` if the render loop should sleep and re-check.
    static func shouldPauseRender(
        offset: Int,
        currentPlaybackIndex: Int,
        lookAhead: Int,
        isPlaying: Bool,
        isAwaitingChapter: Bool
    ) -> Bool {
        // Chapter 0 always renders immediately — there is nothing to play yet.
        guard offset > 0 else { return false }

        // Too far ahead of playback?
        if currentPlaybackIndex + lookAhead < offset { return true }

        // User paused and the player isn't waiting at the queue end for
        // this chapter? Pause the render to avoid unbounded buffering.
        if !isPlaying, !isAwaitingChapter { return true }

        return false
    }

    /// Whether the book was switched mid-render, which should abort the
    /// current render task without stamping a stale error.
    ///
    /// - Parameters:
    ///   - currentFolderURL: The player's current folder URL (may be `nil` if
    ///     no book is loaded).
    ///   - audiobookID: The audiobook ID captured when this render started.
    /// - Returns: `true` if the book changed since the render began.
    static func bookWasSwitched(
        currentFolderURL: String?,
        audiobookID: String
    ) -> Bool {
        currentFolderURL != audiobookID
    }
}
