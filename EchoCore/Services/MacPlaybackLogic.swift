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
    ///     here; `.bookmark` looping is handled elsewhere and `.off` is inert.
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
