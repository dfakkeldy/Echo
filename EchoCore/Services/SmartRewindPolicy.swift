// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The three-tier smart-rewind rules as a pure value, shared by playback
/// (PlayerModel) and the settings screen's live example footer (audit E6:
/// teach by example, not by table).
struct SmartRewindPolicy {
    let secondsThreshold: Int   // seconds
    let secondsAmount: Int      // seconds
    let minutesThreshold: Int   // minutes
    let minutesAmount: Int      // seconds
    let hoursThreshold: Int     // hours
    let hoursAmount: Int        // seconds

    /// Longer-pause rules override shorter ones (same semantics as the
    /// previous PlayerModel.smartRewindAmount).
    func rewindAmount(forPausedDuration pausedDuration: TimeInterval) -> Int {
        var amount = 0
        if pausedDuration >= Double(secondsThreshold) { amount = secondsAmount }
        if pausedDuration >= Double(minutesThreshold * 60) { amount = minutesAmount }
        if pausedDuration >= Double(hoursThreshold * 3600) { amount = hoursAmount }
        return amount
    }

    func exampleText(forPausedMinutes minutes: Int) -> String {
        let amount = rewindAmount(forPausedDuration: Double(minutes * 60))
        return String(localized: "Paused \(minutes) min → rewinds \(amount) s")
    }
}
