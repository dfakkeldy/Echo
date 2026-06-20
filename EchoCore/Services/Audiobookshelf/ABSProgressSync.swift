// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Pure, testable policy helpers for ABS progress push throttling + finished detection.
enum ABSProgressSync {
    /// Throttle: push only while playing and at most once per `minInterval` seconds.
    static func shouldPush(
        now: TimeInterval,
        lastPushAt: TimeInterval?,
        minInterval: TimeInterval,
        isPlaying: Bool
    ) -> Bool {
        guard isPlaying else { return false }
        guard let lastPushAt else { return true }
        return now - lastPushAt >= minInterval
    }

    /// "Finished" once within ~15s of the end (or past it).
    static func isFinished(currentTime: Double, duration: Double, tailSeconds: Double = 15) -> Bool
    {
        guard duration > 0 else { return false }
        return currentTime >= duration - tailSeconds
    }
}
