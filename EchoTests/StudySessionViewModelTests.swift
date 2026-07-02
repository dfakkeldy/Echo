// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Synchronization
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

        try viewModel.loadQueue(
            now: StudyQueueFixtures.mondayNoon, calendar: StudyQueueFixtures.calendar)

        let introducedDates = try studyPlanItemIntroducedDates(in: service)
        #expect(
            viewModel.queue.entries.map(\.category) == [
                .dueReview, .inProgressAssignment, .newAssignment,
            ])
        #expect(viewModel.queue.newAssignmentCount == 1)
        #expect(
            introducedDates == [
                StudyQueueFixtures.mondayNoon.addingTimeInterval(-86_400).ISO8601Format(),
                StudyQueueFixtures.mondayNoon.ISO8601Format(),
                nil,
            ])
        #expect(notificationCounts == [2])
    }

    @Test func loadQueueAppliesGlobalNewChapterLimitBeforeMarkingIntroducedItems() throws {
        let service = try StudyQueueFixtures.serviceWithTwoPlans()
        let viewModel = StudySessionViewModel(
            db: service.writer, updateReviewNotification: { _ in })

        try viewModel.loadQueue(
            now: StudyQueueFixtures.mondayNoon,
            calendar: StudyQueueFixtures.calendar,
            modeOverride: .bookByBook,
            globalNewChapterLimit: 1
        )

        let newCards = viewModel.queue.entries
            .filter { $0.category == .newAssignment }
            .map(\.flashcard.frontText)
        let introducedCards = try introducedAssignmentFrontTexts(in: service)

        #expect(newCards == ["Book A Chapter 1"])
        #expect(viewModel.queue.newAssignmentCount == 1)
        #expect(introducedCards == ["Book A Chapter 1"])
    }

    @Test func loadQueueResetsSessionState() throws {
        let service = try StudyQueueFixtures.serviceWithPlan(chapterLimit: 1)
        let viewModel = StudySessionViewModel(
            db: service.writer, updateReviewNotification: { _ in })
        viewModel.currentIndex = 2
        viewModel.isRevealed = true
        viewModel.errorMessage = "Previous error"

        try viewModel.loadQueue(
            now: StudyQueueFixtures.mondayNoon, calendar: StudyQueueFixtures.calendar)

        #expect(viewModel.currentIndex == 0)
        #expect(viewModel.isRevealed == false)
        #expect(viewModel.errorMessage == nil)
        #expect(viewModel.progress.current == 1)
        #expect(viewModel.progress.total == viewModel.queue.totalCount)
    }

    @Test func gradeCurrentUsesFSRSLogsReviewAndAdvances() throws {
        let service = try StudyQueueFixtures.serviceWithDueCard()
        var notificationCounts: [Int] = []
        // The observer block is `@Sendable`; the counter lives behind a `Mutex`
        // rather than a captured `var` (Swift 6 forbids mutating captured vars from
        // concurrently-executing code). `notificationCounts` stays a plain var — it
        // is only mutated by the non-Sendable `updateReviewNotification` closure.
        let queueChangePostCount = Mutex(0)
        let observer = NotificationCenter.default.addObserver(
            forName: .studyQueueDidChange,
            object: nil,
            queue: nil
        ) { _ in
            queueChangePostCount.withLock { $0 += 1 }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let viewModel = StudySessionViewModel(
            db: service.writer,
            updateReviewNotification: { notificationCounts.append($0) }
        )
        try viewModel.loadQueue(
            now: StudyQueueFixtures.mondayNoon, calendar: StudyQueueFixtures.calendar)
        viewModel.reveal()

        viewModel.gradeCurrent(.good, now: StudyQueueFixtures.mondayNoon)

        let reviewed = try #require(
            try service.read { db in
                try Flashcard.fetchOne(db, key: "due-card")
            })
        let event = try #require(
            try service.read { db in
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
        #expect(queueChangePostCount.withLock { $0 } == 2)
        #expect(event["event_type"] as String == RealTimeEventType.flashcardReviewed.rawValue)
        #expect(event["started_at"] as String == StudyQueueFixtures.mondayNoon.ISO8601Format())
        #expect(event["ended_at"] as String == StudyQueueFixtures.mondayNoon.ISO8601Format())
        #expect(event["source_item_id"] as String == "due-card")
        #expect(event["source_item_type"] as String == "flashcard")
        #expect(metadata["cardId"] as? String == "due-card")
        #expect(metadata["grade"] as? Int == ReviewGrade.good.rawValue)
        #expect(metadata["intervalDays"] as? Int == 1)
    }

    @Test func gradeCurrentUpdatesNotificationCountUsingOnlyDueAndInProgressRemaining() throws {
        let service = try StudyQueueFixtures.serviceWithPlan(chapterLimit: 1)
        var notificationCounts: [Int] = []
        let viewModel = StudySessionViewModel(
            db: service.writer,
            updateReviewNotification: { notificationCounts.append($0) }
        )
        try viewModel.loadQueue(
            now: StudyQueueFixtures.mondayNoon, calendar: StudyQueueFixtures.calendar)

        viewModel.gradeCurrent(.good, now: StudyQueueFixtures.mondayNoon)

        #expect(
            viewModel.queue.entries.map(\.category) == [
                .dueReview, .inProgressAssignment, .newAssignment,
            ])
        #expect(viewModel.currentIndex == 1)
        #expect(notificationCounts == [2, 1])
    }

    @Test func playAssignmentCallsPlaybackClosureForListeningAndImageAssignments() throws {
        let service = try StudyQueueFixtures.serviceWithImagePlan(chapterLimit: 1)
        let viewModel = StudySessionViewModel(
            db: service.writer, updateReviewNotification: { _ in })
        var requestedCardIDs: [String] = []
        viewModel.onRequestAssignmentPlayback = { card in requestedCardIDs.append(card.id) }

        try viewModel.loadQueue(
            now: StudyQueueFixtures.mondayNoon, calendar: StudyQueueFixtures.calendar)
        let listeningID = try #require(viewModel.currentEntry?.flashcard.id)
        #expect(
            viewModel.currentEntry?.flashcard.cardType == StudyFlashcardType.listeningAssignment)
        viewModel.requestPlayCurrentAssignment()

        viewModel.advance()
        let imageID = try #require(viewModel.currentEntry?.flashcard.id)
        #expect(viewModel.currentEntry?.flashcard.cardType == StudyFlashcardType.imageAssignment)
        viewModel.requestPlayCurrentAssignment()

        #expect(requestedCardIDs == [listeningID, imageID])
    }

    @Test func playAssignmentIgnoresNormalCardsAndEmptySessions() throws {
        let service = try StudyQueueFixtures.serviceWithDueCard()
        let viewModel = StudySessionViewModel(
            db: service.writer, updateReviewNotification: { _ in })
        var requestCount = 0
        viewModel.onRequestAssignmentPlayback = { _ in requestCount += 1 }

        try viewModel.loadQueue(
            now: StudyQueueFixtures.mondayNoon, calendar: StudyQueueFixtures.calendar)
        #expect(viewModel.currentEntry?.flashcard.cardType == StudyFlashcardType.normal)
        viewModel.requestPlayCurrentAssignment()

        viewModel.advance()
        viewModel.requestPlayCurrentAssignment()

        #expect(requestCount == 0)
    }

    @Test func skipCurrentWritesNoGradeDefersToTomorrowAndAdvances() throws {
        let service = try StudyQueueFixtures.serviceWithTwoPlansIncludingProgress()
        let viewModel = StudySessionViewModel(
            db: service.writer, updateReviewNotification: { _ in })
        try viewModel.loadQueue(
            now: StudyQueueFixtures.mondayNoon, calendar: StudyQueueFixtures.calendar)

        let entry = try #require(viewModel.currentEntry)
        #expect(entry.flashcard.frontText == "Book A Chapter 1")
        #expect(viewModel.currentEntryIsSkipEligible() == true)

        viewModel.skipCurrent(now: StudyQueueFixtures.mondayNoon)

        let skipped = try #require(
            try service.read { db in try Flashcard.fetchOne(db, key: entry.flashcard.id) })
        let tomorrow = StudyQueueFixtures.calendar.date(
            byAdding: .day, value: 1, to: StudyQueueFixtures.mondayNoon)!
        #expect(skipped.lastGrade == nil)
        #expect(skipped.nextReviewDate == tomorrow.ISO8601Format())
        #expect(viewModel.currentIndex == 1)
    }

    @Test func skipIsNotOfferedWhenTheChapterHasUserCards() throws {
        let service = try StudyQueueFixtures.serviceWithTwoPlansIncludingProgress()
        try StudyQueueFixtures.seedDueCard(
            id: "user-1",
            audiobookID: "book-a",
            frontText: "My card",
            nextReviewDate: StudyQueueFixtures.mondayNoon.addingTimeInterval(86_400),
            isEnabled: true,
            in: service
        )
        let viewModel = StudySessionViewModel(
            db: service.writer, updateReviewNotification: { _ in })
        try viewModel.loadQueue(
            now: StudyQueueFixtures.mondayNoon, calendar: StudyQueueFixtures.calendar)

        let entry = try #require(viewModel.currentEntry)
        #expect(entry.flashcard.frontText == "Book A Chapter 1")
        #expect(viewModel.currentEntryIsSkipEligible() == false)
    }

    @Test func skipCurrentIgnoresIneligibleAssignmentCards() throws {
        let service = try StudyQueueFixtures.serviceWithTwoPlansIncludingProgress()
        try StudyQueueFixtures.seedDueCard(
            id: "user-1",
            audiobookID: "book-a",
            frontText: "My card",
            nextReviewDate: StudyQueueFixtures.mondayNoon.addingTimeInterval(86_400),
            isEnabled: true,
            in: service
        )
        var notificationCounts: [Int] = []
        let viewModel = StudySessionViewModel(
            db: service.writer,
            updateReviewNotification: { notificationCounts.append($0) }
        )
        try viewModel.loadQueue(
            now: StudyQueueFixtures.mondayNoon, calendar: StudyQueueFixtures.calendar)

        let entry = try #require(viewModel.currentEntry)
        #expect(viewModel.currentEntryIsSkipEligible() == false)

        viewModel.skipCurrent(now: StudyQueueFixtures.mondayNoon)

        let unchanged = try #require(
            try service.read { db in try Flashcard.fetchOne(db, key: entry.flashcard.id) })
        #expect(unchanged.nextReviewDate == entry.flashcard.nextReviewDate)
        #expect(viewModel.currentIndex == 0)
        #expect(notificationCounts == [2])
    }

    @Test func skipCurrentIgnoresNormalCards() throws {
        let service = try StudyQueueFixtures.serviceWithDueCard()
        let viewModel = StudySessionViewModel(
            db: service.writer, updateReviewNotification: { _ in })
        try viewModel.loadQueue(
            now: StudyQueueFixtures.mondayNoon, calendar: StudyQueueFixtures.calendar)

        let entry = try #require(viewModel.currentEntry)
        viewModel.skipCurrent(now: StudyQueueFixtures.mondayNoon)

        let unchanged = try #require(
            try service.read { db in try Flashcard.fetchOne(db, key: entry.flashcard.id) })
        #expect(unchanged.nextReviewDate == entry.flashcard.nextReviewDate)
        #expect(viewModel.currentIndex == 0)
    }

    @Test func needsAttentionFlagsLoadWithTheQueue() throws {
        let service = try StudyQueueFixtures.serviceWithTwoPlansIncludingProgress()
        let queue = StudyPlaybackQueueService(db: service.writer)
        try queue.markNeedsAttention(
            item: StudyPlayableItem(
                flashcardID: "card-x",
                audiobookID: "book-a",
                chapterIndex: 0,
                planItemID: nil,
                title: "Book A Chapter 1",
                startTime: 0,
                endTime: 100
            ),
            reason: "Book not downloaded",
            now: StudyQueueFixtures.mondayNoon
        )

        let viewModel = StudySessionViewModel(
            db: service.writer, updateReviewNotification: { _ in })
        try viewModel.loadQueue(
            now: StudyQueueFixtures.mondayNoon, calendar: StudyQueueFixtures.calendar)

        #expect(viewModel.needsAttentionCardIDs.contains("card-x"))
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

    private func introducedAssignmentFrontTexts(in service: DatabaseService) throws -> [String] {
        try service.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT flashcard.front_text
                    FROM study_plan_item
                    JOIN flashcard ON flashcard.id = study_plan_item.flashcard_id
                    WHERE study_plan_item.introduced_at IS NOT NULL
                    ORDER BY study_plan_item.introduced_at, flashcard.front_text
                    """
            )
        }
    }
}
