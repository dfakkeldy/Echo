// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Seeds FSRS memory state from a legacy SM-2 card's fields. This is a heuristic
/// proxy, not a perfect reconstruction: the SM-2 interval approximates FSRS
/// stability (the day-interval at ~90% retention), and the SM-2 ease factor maps
/// inversely to FSRS difficulty (lower ease = harder card = higher difficulty;
/// the SM-2 default ease 2.5 maps to a neutral difficulty of 5).
enum FSRSMigration {
    static func seed(intervalDays: Int, easeFactor: Double)
        -> (stability: Double, difficulty: Double)
    {
        let stability = max(0.1, Double(intervalDays))
        let rawDifficulty = 5.0 - (easeFactor - 2.5) * 5.0
        let difficulty = min(max(rawDifficulty, 1.0), 10.0)
        return (stability, difficulty)
    }
}
