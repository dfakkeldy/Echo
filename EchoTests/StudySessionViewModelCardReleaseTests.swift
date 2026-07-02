// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct StudySessionViewModelCardReleaseTests {
    @Test func loadQueueDoesNotReleaseUntilNewCardIsCurrent() throws {
        let service = try StudyQueueFixtures.serviceWithPlan()
        try StudyCardFixtures.seedAcceptedCard(
            id: "card-1", chapterIndex: 0, ordinal: 100, in: service)
        let viewModel = StudySessionViewModel(db: service.writer, updateReviewNotification: { _ in })

        try viewModel.loadQueue(
            now: StudyQueueFixtures.mondayNoon,
            calendar: StudyQueueFixtures.calendar,
            globalNewCardLimit: 20
        )

        #expect(viewModel.currentEntry?.category == .dueReview)
        #expect(try cardReleaseRow(id: "card-1", in: service).introducedAt == nil)

        while viewModel.currentEntry?.category != .newCard, !viewModel.isComplete {
            viewModel.advance(now: StudyQueueFixtures.mondayNoon)
        }

        let released = try cardReleaseRow(id: "card-1", in: service)
        #expect(viewModel.currentEntry?.category == .newCard)
        #expect(released.nextReviewDate == StudyQueueFixtures.mondayNoon.ISO8601Format())
        #expect(released.introducedAt == StudyQueueFixtures.mondayNoon.ISO8601Format())
    }

    @Test func firstEntryNewCardReleasesOnLoadBecauseItIsCurrent() throws {
        let service = try StudyQueueFixtures.serviceWithPlan()
        try service.write { db in
            try db.execute(sql: "DELETE FROM flashcard WHERE id = 'due'")
            try db.execute(sql: "DELETE FROM study_plan_item WHERE kind = 'chapter'")
            try db.execute(
                sql: """
                    INSERT INTO study_plan_item (
                        id, plan_id, flashcard_id, kind, chapter_index, ordinal,
                        introduced_at, is_enabled, created_at, modified_at
                    )
                    SELECT 'chapter-anchor', id, NULL, 'chapter', 0, 0, ?, 1, ?, ?
                    FROM study_plan
                    """,
                arguments: [
                    StudyQueueFixtures.mondayNoon.addingTimeInterval(-86_400).ISO8601Format(),
                    StudyQueueFixtures.mondayNoon.ISO8601Format(),
                    StudyQueueFixtures.mondayNoon.ISO8601Format(),
                ]
            )
        }
        try StudyCardFixtures.seedAcceptedCard(
            id: "card-1", chapterIndex: 0, ordinal: 100, in: service)
        let viewModel = StudySessionViewModel(db: service.writer, updateReviewNotification: { _ in })

        try viewModel.loadQueue(
            now: StudyQueueFixtures.mondayNoon,
            calendar: StudyQueueFixtures.calendar,
            globalNewCardLimit: 20
        )

        let released = try cardReleaseRow(id: "card-1", in: service)
        #expect(viewModel.currentEntry?.category == .newCard)
        #expect(released.nextReviewDate == StudyQueueFixtures.mondayNoon.ISO8601Format())
    }

    @Test func releaseCardsIsScopedAndIdempotent() throws {
        let service = try StudyQueueFixtures.serviceWithPlan()
        try StudyCardFixtures.seedAcceptedCard(
            id: "card-a", chapterIndex: 0, ordinal: 100, in: service)
        try StudyCardFixtures.seedAcceptedCard(
            id: "card-b", chapterIndex: 0, ordinal: 101, in: service)

        try StudyPlanDAO(db: service.writer).releaseCards(
            itemIDs: ["item-card-a"], now: StudyQueueFixtures.mondayNoon)

        #expect(
            try cardReleaseRow(id: "card-a", in: service).nextReviewDate
                == StudyQueueFixtures.mondayNoon.ISO8601Format())
        #expect(try cardReleaseRow(id: "card-b", in: service).nextReviewDate == nil)

        try StudyPlanDAO(db: service.writer).releaseCards(
            itemIDs: ["item-card-a"],
            now: StudyQueueFixtures.mondayNoon.addingTimeInterval(60)
        )

        #expect(
            try cardReleaseRow(id: "card-a", in: service).nextReviewDate
                == StudyQueueFixtures.mondayNoon.ISO8601Format())
    }

    private func cardReleaseRow(
        id: String,
        in service: DatabaseService
    ) throws -> (nextReviewDate: String?, introducedAt: String?) {
        try service.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT flashcard.next_review_date, study_plan_item.introduced_at
                    FROM flashcard
                    JOIN study_plan_item ON study_plan_item.flashcard_id = flashcard.id
                    WHERE flashcard.id = ?
                    """,
                arguments: [id]
            )
            return (row?["next_review_date"] as String?, row?["introduced_at"] as String?)
        }
    }
}
