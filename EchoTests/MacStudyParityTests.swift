// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// Structural tests for the macOS study system (flashcard daily review). The
/// `Echo macOS` target is not compiled into EchoTests, so we assert against
/// source text via `MacSource`. The view is Mac-native over the shared,
/// macOS-clean DailyReviewViewModel.
struct MacStudyParityTests {

    @Test func dailyReviewViewBindsSharedViewModel() throws {
        let src = try MacSource.read("Views/MacDailyReviewView.swift")
        #expect(
            src.contains("DailyReviewViewModel("),
            "The macOS daily-review view must drive the shared DailyReviewViewModel.")
        #expect(
            src.contains("loadDueCards()") && src.contains("gradeCard("),
            "The review view must load due cards and grade them via the shared FSRS scheduler.")
    }

    @Test func studyMenuOpensDailyReview() throws {
        let app = try MacSource.read("Echo_macOSApp.swift")
        #expect(
            app.contains("requestDailyReview"),
            "A Study menu command must post .requestDailyReview to open daily review.")
        let triPane = try MacSource.read("Views/MacTriPaneView.swift")
        #expect(
            triPane.contains("MacDailyReviewView(") && triPane.contains(".requestDailyReview"),
            "MacTriPaneView must present the daily-review sheet on the .requestDailyReview signal.")
    }
}
