// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Pure, side-effect-free boundary decision for the macOS raw-AVPlayer model.
///
/// macOS uses a raw `AVPlayer` (no `PlaybackController`/`AVAudioEngine`), so
/// chapter looping and end-of-chapter sleep must be enforced by polling
/// `currentTime` inside the periodic time observer. This struct isolates the
/// "what should happen at this instant" decision so it is unit-testable from
/// the `EchoTests` target (which does not compile the `Echo macOS` target).
enum MacChapterLoopDecision: Equatable {
    /// Do nothing this tick.
    case none
    /// Seek the player back to this absolute time (seconds) to loop the chapter.
    case seek(to: Double)
    /// Fire the end-of-chapter sleep timer (pauses playback).
    case fireSleep

    /// Decides the action for the current playback instant.
    ///
    /// - Parameters:
    ///   - currentTime: Current playback position in seconds.
    ///   - chapters: Parsed chapters for the current track (may be empty).
    ///   - currentChapterIndex: Index into `chapters` of the playing chapter.
    ///   - loopMode: The active loop mode. Only `.chapter` triggers a seek-back
    ///     here; `.bookmark` looping is handled by `MacBookmarkLoopDecision`
    ///     and `.off` is inert.
    ///   - isEndOfChapterSleep: Whether the sleep timer is armed for end-of-chapter.
    /// - Returns: The action to perform. Chapter-loop takes priority over the
    ///   end-of-chapter sleep when both are armed.
    static func evaluate(
        currentTime: Double,
        chapters: [Chapter],
        currentChapterIndex: Int,
        loopMode: LoopMode,
        isEndOfChapterSleep: Bool
    ) -> MacChapterLoopDecision {
        guard chapters.indices.contains(currentChapterIndex) else { return .none }
        let chapter = chapters[currentChapterIndex]

        // Boundary = we have reached (or passed) the end of the current chapter.
        let atBoundary = currentTime >= chapter.endSeconds

        if loopMode == .chapter {
            return atBoundary ? .seek(to: chapter.startSeconds) : .none
        }

        if isEndOfChapterSleep, atBoundary {
            return .fireSleep
        }

        return .none
    }
}

/// Pure A–B bookmark-loop decision for the macOS raw-AVPlayer model.
///
/// Mirrors the iOS `PlaybackController.applyBookmarkLoopIfNeeded`: with two or
/// more enabled bookmarks, playback repeats the segment between the two
/// bookmarks bracketing the playhead. As the playhead approaches the *next*
/// bookmark it seeks back to the *previous* one, so the listener loops a single
/// A→B span. Because macOS enforces this by polling `currentTime` in the time
/// observer (no `AVAudioEngine` callbacks), the decision is isolated here so it
/// is unit-testable from the `EchoTests` target.
enum MacBookmarkLoopDecision {
    /// Returns the absolute time (seconds) to seek back to in order to loop the
    /// current bookmark segment, or `nil` to keep playing.
    ///
    /// - Parameters:
    ///   - currentTime: Current playback position in seconds.
    ///   - bookmarkTimes: Timestamps of the *enabled* bookmarks for the current
    ///     track, **ascending**. Fewer than two means there is no segment to
    ///     loop, so the result is always `nil`.
    ///   - speed: Current playback rate; widens the look-ahead so faster speeds
    ///     still catch the boundary between two 0.5s polls.
    /// - Returns: A seek-back target, or `nil`.
    static func seekBackTarget(
        currentTime t: Double,
        bookmarkTimes: [Double],
        speed: Float
    ) -> Double? {
        guard t.isFinite, bookmarkTimes.count >= 2 else { return nil }
        // The segment is [startIdx, startIdx+1): the last bookmark before `t`
        // and the next one after it.
        guard let startIdx = bookmarkTimes.lastIndex(where: { $0 < t }) else { return nil }
        let endIdx = startIdx + 1
        guard endIdx < bookmarkTimes.count else {
            // Past the final bookmark: if we have only just crossed it, loop the
            // last segment by seeking to the second-to-last bookmark. Mirrors the
            // iOS "< 1.0s past the last bookmark" tail case.
            if t - bookmarkTimes[bookmarkTimes.count - 1] < 1.0 {
                return bookmarkTimes[bookmarkTimes.count - 2] + 0.05
            }
            return nil
        }
        let lookAhead = max(0.5, 0.3 * Double(speed))
        if t >= bookmarkTimes[endIdx] - lookAhead {
            return bookmarkTimes[startIdx] + 0.05
        }
        return nil
    }
}

/// Pure dB→linear conversion for the macOS volume boost. Kept in
/// `EchoCore/Services/` so it is unit-testable from EchoTests; the audio-tap
/// plumbing lives in the macOS target. Returns a linear amplitude multiplier
/// (1.0 == unity / no change).
enum MacVolumeBoost {
    static func linearGain(enabled: Bool, gainDB: Float) -> Float {
        guard enabled else { return 1.0 }
        return powf(10.0, gainDB / 20.0)
    }
}
