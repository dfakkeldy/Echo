// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct StudySessionViewModelTests {
    @Test func loadQueueMarksOnlyReturnedNewAssignmentItemsIntroduced() throws {
        let service = try StudyQueueFixtures.serviceWithPlan(chapterLimit: 1)
        var notificationCounts: [Int] = []
        let viewModel = StudySessionViewModel(
            db: service.writer,
            updateReviewNotification: { notificationCounts.append($0) }
        )

        try viewModel.loadQueue(now: StudyQueueFixtures.mondayNoon, calendar: StudyQueueFixtures.calendar)

        let introducedDates = try studyPlanItemIntroducedDates(in: service)
        #expect(viewModel.queue.entries.map(\.category) == [.dueReview, .inProgressAssignment, .newAssignment])
        #expect(viewModel.queue.newAssignmentCount == 1)
        #expect(introducedDates == [
            StudyQueueFixtures.mondayNoon.addingTimeInterval(-86_400).ISO8601Format(),
            StudyQueueFixtures.mondayNoon.ISO8601Format(),
            nil,
        ])
        #expect(notificationCounts == [2])
    }

    @Test func loadQueueResetsSessionState() throws {
        let service = try StudyQueueFixtures.serviceWithPlan(chapterLimit: 1)
        let viewModel = StudySessionViewModel(db: service.writer, updateReviewNotification: { _ in })
        viewModel.currentIndex = 2
        viewModel.isRevealed = true
        viewModel.errorMessage = "Previous error"

        try viewModel.loadQueue(now: StudyQueueFixtures.mondayNoon, calendar: StudyQueueFixtures.calendar)

        #expect(viewModel.currentIndex == 0)
        #expect(viewModel.isRevealed == false)
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.progress.current == 1)
        #expect(viewModel.progress.total == viewModel.queue.totalCount)
    }

    @Test func gradeCurrentUsesFSRSLogsReviewAndAdvances() throws {
        let service = try StudyQueueFixtures.serviceWithDueCard()
        var notificationCounts: [Int] = []
        let viewModel = StudySessionViewModel(
            db: service.writer,
            updateReviewNotification: { notificationCounts.append($0) }
        )
        try viewModel.loadQueue(now: StudyQueueFixtures.mondayNoon, calendar: StudyQueueFixtures.calendar)
        viewModel.reveal()

        viewModel.gradeCurrent(.good, now: StudyQueueFixtures.mondayNoon)

        let reviewed = try #require(try service.read { db in
            try Flashcard.fetchOne(db, key: "due-card")
        })
        let event = try #require(try service.read { db in
            try Row.fetchOne(
                db,
                sql: """
                    SELECT event_type, started_at, ended_at, metadata_json, source_item_id, source_item_type
                    FROM real_time_event
                    WHERE source_item_id = ?
                    """,
                arguments: ["due-card"]
            )
        })
        let metadataJSON: String = event["metadata_json"]
        let metadata = try #require(
            JSONSerialization.jsonObject(with: Data(metadataJSON.utf8)) as? [String: Any]
        )

        #expect(reviewed.lastGrade == ReviewGrade.good.rawValue)
        #expect(reviewed.repetitions == 1)
        #expect(reviewed.stability != nil)
        #expect(viewModel.currentIndex == 1)
        #expect(viewModel.isRevealed == false)
        #expect(viewModel.isComplete)
        #expect(notificationCounts == [1, 0])
        #expect(event["event_type"] as String == RealTimeEventType.flashcardReviewed.rawValue)
        #expect(event["started_at"] as String == StudyQueueFixtures.mondayNoon.ISO8601Format())
        #expect(event["ended_at"] as String == StudyQueueFixtures.mondayNoon.ISO8601Format())
        #expect(event["source_item_id"] as String == "due-card")
        #expect(event["source_item_type"] as String == "flashcard")
        #expect(metadata["cardId"] as? String == "due-card")
        #expect(metadata["grade"] as? Int == ReviewGrade.good.rawValue)
    }

    @Test func gradeCurrentUpdatesNotificationCountUsingOnlyDueAndInProgressRemaining() throws {
        let service = try StudyQueueFixtures.serviceWithPlan(chapterLimit: 1)
        var notificationCounts: [Int] = []
        let viewModel = StudySessionViewModel(
            db: service.writer,
            updateReviewNotification: { notificationCounts.append($0) }
        )
        try viewModel.loadQueue(now: StudyQueueFixtures.mondayNoon, calendar: StudyQueueFixtures.calendar)

        viewModel.gradeCurrent(.good, now: StudyQueueFixtures.mondayNoon)

        #expect(viewModel.queue.entries.map(\.category) == [.dueReview, .inProgressAssignment, .newAssignment])
        #expect(viewModel.currentIndex == 1)
        #expect(notificationCounts == [2, 1])
    }

    @Test func playAssignmentCallsPlaybackClosureForListeningAndImageAssignments() throws {
        let service = try StudyQueueFixtures.serviceWithImagePlan(chapterLimit: 1)
        let viewModel = StudySessionViewModel(db: service.writer, updateReviewNotification: { _ in })
        var requestedCardIDs: [String] = []
        viewModel.onRequestAssignmentPlayback = { card in requestedCardIDs.append(card.id) }

        try viewModel.loadQueue(now: StudyQueueFixtures.mondayNoon, calendar: StudyQueueFixtures.calendar)
        let listeningID = try #require(viewModel.currentEntry?.flashcard.id)
        #expect(viewModel.currentEntry?.flashcard.cardType == StudyFlashcardType.listeningAssignment)
        viewModel.requestPlayCurrentAssignment()

        viewModel.advance()
        let imageID = try #require(viewModel.currentEntry?.flashcard.id)
        #expect(viewModel.currentEntry?.flashcard.cardType == StudyFlashcardType.imageAssignment)
        viewModel.requestPlayCurrentAssignment()

        #expect(requestedCardIDs == [listeningID, imageID])
    }

    @Test func playAssignmentIgnoresNormalCardsAndEmptySessions() throws {
        let service = try StudyQueueFixtures.serviceWithDueCard()
        let viewModel = StudySessionViewModel(db: service.writer, updateReviewNotification: { _ in })
        var requestCount = 0
        viewModel.onRequestAssignmentPlayback = { _ in requestCount += 1 }

        try viewModel.loadQueue(now: StudyQueueFixtures.mondayNoon, calendar: StudyQueueFixtures.calendar)
        #expect(viewModel.currentEntry?.flashcard.cardType == StudyFlashcardType.normal)
        viewModel.requestPlayCurrentAssignment()

        viewModel.advance()
        viewModel.requestPlayCurrentAssignment()

        #expect(requestCount == 0)
    }

    private func studyPlanItemIntroducedDates(in service: DatabaseService) throws -> [String?] {
        try service.read { db in
            try Row.fetchAll(
                db,
                sql: "SELECT introduced_at FROM study_plan_item ORDER BY ordinal"
            )
            .map { row in row["introduced_at"] as String? }
        }
    }
}
