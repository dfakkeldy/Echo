// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

struct WatchReviewFeedbackPolicyTests {
    @Test func failingGradeUsesAgainFeedback() {
        #expect(WatchReviewFeedbackPolicy.feedback(forGrade: 0) == .again)
    }

    @Test func rememberedGradesUseRememberedFeedback() {
        #expect(WatchReviewFeedbackPolicy.feedback(forGrade: 3) == .remembered)
        #expect(WatchReviewFeedbackPolicy.feedback(forGrade: 5) == .remembered)
    }
}
