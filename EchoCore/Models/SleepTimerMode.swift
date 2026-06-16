// SPDX-License-Identifier: GPL-3.0-or-later
/// Controls when playback should automatically pause.
enum SleepTimerMode: Equatable {
    /// No sleep timer is active.
    case off
    /// Pause after the given number of minutes elapses.
    case minutes(Int)
    /// Pause when the current chapter ends.
    case endOfChapter

    /// Whether a sleep timer is currently armed.
    var isActive: Bool {
        if case .off = self { return false }
        return true
    }
}
