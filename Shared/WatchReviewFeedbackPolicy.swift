// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum WatchReviewFeedback: Equatable, Sendable {
    case reveal
    case again
    case remembered
}

enum WatchReviewFeedbackPolicy {
    nonisolated static func feedback(forGrade grade: Int) -> WatchReviewFeedback {
        grade <= 0 ? .again : .remembered
    }
}
