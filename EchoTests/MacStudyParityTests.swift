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

    @Test func cardInboxReviewsMarkedPassages() throws {
        let src = try MacSource.read("Views/MacCardInboxView.swift")
        #expect(
            src.contains("MarkedPassageDAO(db:") && src.contains("fetchAllInbox()"),
            "The Card Inbox must load marked passages via the shared MarkedPassageDAO.")
        #expect(
            src.contains("markConverted(") && src.contains(".dismiss(id:"),
            "The Card Inbox must support convert-to-flashcard and dismiss.")
        #expect(
            src.contains("FlashcardDAO(db:") && src.contains(".insert("),
            "Convert must create a flashcard via the shared FlashcardDAO.")
    }

    @Test func studyMenuOpensCardInbox() throws {
        let app = try MacSource.read("Echo_macOSApp.swift")
        #expect(
            app.contains("requestCardInbox"),
            "A Study menu command must post .requestCardInbox to open the Card Inbox.")
        let triPane = try MacSource.read("Views/MacTriPaneView.swift")
        #expect(
            triPane.contains("MacCardInboxView(") && triPane.contains(".requestCardInbox"),
            "MacTriPaneView must present the Card Inbox sheet on the .requestCardInbox signal.")
    }
}
