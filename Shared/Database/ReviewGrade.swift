// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// The canonical review grade — the four-button FSRS scale. Raw values are the
/// exact grades `FSRSScheduler` expects: 1 = Again, 2 = Hard, 3 = Good, 4 = Easy.
/// Introduced to prevent the prior 0–5-vs-1–4 mismatch that mis-fed FSRS.
enum ReviewGrade: Int, CaseIterable, Sendable {
    case again = 1
    case hard = 2
    case good = 3
    case easy = 4

    var label: String {
        switch self {
        case .again: return "Again"
        case .hard: return "Hard"
        case .good: return "Good"
        case .easy: return "Easy"
        }
    }
}
