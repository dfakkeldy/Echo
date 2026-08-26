// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Pure decision for what tapping a read-along paragraph card should do, kept out
/// of the view so it's unit-testable and shared by the iOS and macOS readers.
///
/// A block has an audio time only once it's narrated/aligned (the materialized
/// `timeline_item.audio_start_time`); un-narrated/un-aligned blocks store the
/// sentinel `-1` (or have no row → `nil`). Tapping a timed card should seek there
/// and start playing; tapping an un-timed card should give feedback, not a silent
/// no-op (the reported "tapping a card does nothing" bug).
enum CardTapDecision: Equatable {
    case seekAndPlay(seconds: Double)
    case noTime

    static func make(time: Double?) -> CardTapDecision {
        guard let time, time >= 0 else { return .noTime }
        return .seekAndPlay(seconds: time)
    }
}
