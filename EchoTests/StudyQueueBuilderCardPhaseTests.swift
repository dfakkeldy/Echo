// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct StudyQueueBuilderCardPhaseTests {
    @Test func cardsReleaseOnlyAfterTheirChapterIsIntroduced() throws {
        let service = try StudyQueueFixtures.serviceWithPlan()
        try StudyCardFixtures.seedAcceptedCard(
            id: "card-ch0", chapterIndex: 0, ordinal: 100, in: service)
        try StudyCardFixtures.seedAcceptedCard(
            id: "card-ch1", chapterIndex: 1, ordinal: 101, in: service)

        let queue = try StudyQueueBuilder(db: service.writer).build(
            now: StudyQueueFixtures.mondayNoon,
            calendar: StudyQueueFixtures.calendar,
            globalNewCardLimit: 20
        )

        #expect(newCardTitles(in: queue) == ["Card card-ch0"])
    }

    @Test func perPlanBudgetIsMinOfPlanAndGlobal() throws {
        let service = try StudyQueueFixtures.serviceWithPlan()
        for index in 0..<3 {
            try StudyCardFixtures.seedAcceptedCard(
                id: "card-\(index)", chapterIndex: 0, ordinal: 100 + index, in: service)
        }
        let builder = StudyQueueBuilder(db: service.writer)

        let globallyCapped = try builder.build(
            now: StudyQueueFixtures.mondayNoon,
            calendar: StudyQueueFixtures.calendar,
            globalNewCardLimit: 1
        )
        #expect(newCardTitles(in: globallyCapped) == ["Card card-0"])

        try service.write { db in
            try db.execute(sql: "UPDATE study_plan SET new_cards_per_day = 1")
        }
        let planCapped = try builder.build(
            now: StudyQueueFixtures.mondayNoon,
            calendar: StudyQueueFixtures.calendar,
            globalNewCardLimit: 20
        )
        #expect(newCardTitles(in: planCapped) == ["Card card-0"])
    }

    @Test func gentleBudgetCountsCardsReleasedToday() throws {
        let service = try StudyQueueFixtures.serviceWithPlan(startDaysBeforeNow: 1)
        try service.write { db in
            try db.execute(sql: "UPDATE study_plan SET new_cards_per_day = 3")
        }
        try StudyCardFixtures.seedAcceptedCard(
            id: "released-1", chapterIndex: 0, ordinal: 100, released: true, in: service)
        try StudyCardFixtures.seedAcceptedCard(
            id: "released-2", chapterIndex: 0, ordinal: 101, released: true, in: service)
        try StudyCardFixtures.seedAcceptedCard(
            id: "pending-1", chapterIndex: 0, ordinal: 102, in: service)
        try StudyCardFixtures.seedAcceptedCard(
            id: "pending-2", chapterIndex: 0, ordinal: 103, in: service)

        let queue = try StudyQueueBuilder(db: service.writer).build(
            now: StudyQueueFixtures.mondayNoon,
            calendar: StudyQueueFixtures.calendar,
            globalNewCardLimit: 20
        )

        #expect(newCardTitles(in: queue) == ["Card pending-1"])
    }

    @Test func weeklyPlanStillUsesDailyCardWindows() throws {
        let service = try StudyQueueFixtures.serviceWithPlan(cadenceUnit: .week)
        try service.write { db in
            try db.execute(sql: "UPDATE study_plan SET new_cards_per_day = 1")
        }
        try StudyCardFixtures.seedAcceptedCard(
            id: "yesterday",
            chapterIndex: 0,
            ordinal: 100,
            released: true,
            releasedAt: StudyQueueFixtures.mondayNoon.addingTimeInterval(-86_400),
            in: service
        )
        try StudyCardFixtures.seedAcceptedCard(
            id: "today", chapterIndex: 0, ordinal: 101, in: service)

        let queue = try StudyQueueBuilder(db: service.writer).build(
            now: StudyQueueFixtures.mondayNoon,
            calendar: StudyQueueFixtures.calendar,
            globalNewCardLimit: 20
        )

        #expect(newCardTitles(in: queue) == ["Card today"])
    }

    @Test func cardDrainBlocksNextChapterUntilFrontierCardsDrain() throws {
        let service = try StudyQueueFixtures.serviceWithPlan(chapterLimit: 2)
        try StudyCardFixtures.seedAcceptedCard(
            id: "frontier", chapterIndex: 0, ordinal: 100, in: service)

        let queue = try StudyQueueBuilder(db: service.writer).build(
            now: StudyQueueFixtures.mondayNoon,
            calendar: StudyQueueFixtures.calendar,
            globalNewCardLimit: 20
        )

        #expect(newAssignmentTitles(in: queue).isEmpty)
        #expect(newCardTitles(in: queue) == ["Card frontier"])
    }

    @Test func cardDrainAllowsOneNewChapterAfterFrontierCardsDrain() throws {
        let service = try StudyQueueFixtures.serviceWithPlan(chapterLimit: 2)
        try StudyCardFixtures.seedAcceptedCard(
            id: "frontier", chapterIndex: 0, ordinal: 100, released: true, in: service)

        let queue = try StudyQueueBuilder(db: service.writer).build(
            now: StudyQueueFixtures.mondayNoon,
            calendar: StudyQueueFixtures.calendar,
            globalNewCardLimit: 20
        )

        #expect(newAssignmentTitles(in: queue) == ["Book A Chapter 2"])
    }

    @Test func cadencePacingBypassesCardDrainGate() throws {
        let service = try StudyQueueFixtures.serviceWithPlan(chapterLimit: 2)
        try service.write { db in
            try db.execute(sql: "UPDATE study_plan SET chapter_pacing = 'cadence'")
        }
        try StudyCardFixtures.seedAcceptedCard(
            id: "frontier", chapterIndex: 0, ordinal: 100, in: service)

        let queue = try StudyQueueBuilder(db: service.writer).build(
            now: StudyQueueFixtures.mondayNoon,
            calendar: StudyQueueFixtures.calendar,
            globalNewCardLimit: 20
        )

        #expect(newAssignmentTitles(in: queue) == ["Book A Chapter 2", "Book A Chapter 3"])
    }

    @Test func noCardPlanKeepsStrictCatchUpOpen() throws {
        let service = try StudyQueueFixtures.serviceWithPlan(chapterLimit: 2)
        try service.write { db in
            try db.execute(sql: "UPDATE study_plan SET catch_up_policy = 'strict'")
        }

        let queue = try StudyQueueBuilder(db: service.writer).build(
            now: StudyQueueFixtures.mondayNoon,
            calendar: StudyQueueFixtures.calendar
        )

        #expect(newAssignmentTitles(in: queue) == ["Book A Chapter 2", "Book A Chapter 3"])
    }

    @Test func releasedCardsSurfaceOnlyAsDueReviews() throws {
        let service = try StudyQueueFixtures.serviceWithPlan()
        try StudyCardFixtures.seedAcceptedCard(
            id: "released", chapterIndex: 0, ordinal: 100, released: true, in: service)

        let queue = try StudyQueueBuilder(db: service.writer).build(
            now: StudyQueueFixtures.mondayNoon,
            calendar: StudyQueueFixtures.calendar,
            globalNewCardLimit: 20
        )

        let entries = queue.entries.filter { $0.flashcard.id == "released" }
        #expect(entries.map(\.category) == [.dueReview])
    }

    @Test func chapterCapDoesNotSwallowNewCardEntries() throws {
        let service = try StudyQueueFixtures.serviceWithPlan()
        try StudyCardFixtures.seedAcceptedCard(
            id: "pending", chapterIndex: 0, ordinal: 100, in: service)

        let queue = try StudyQueueBuilder(db: service.writer).build(
            now: StudyQueueFixtures.mondayNoon,
            calendar: StudyQueueFixtures.calendar,
            globalNewChapterLimit: 0,
            globalNewCardLimit: 20
        )

        #expect(newAssignmentTitles(in: queue).isEmpty)
        #expect(newCardTitles(in: queue) == ["Card pending"])
    }

    @Test func passiveBuildDoesNotStampNewCards() throws {
        let service = try StudyQueueFixtures.serviceWithPlan()
        try StudyCardFixtures.seedAcceptedCard(
            id: "pending", chapterIndex: 0, ordinal: 100, in: service)

        _ = try StudyQueueBuilder(db: service.writer).build(
            now: StudyQueueFixtures.mondayNoon,
            calendar: StudyQueueFixtures.calendar,
            globalNewCardLimit: 20
        )

        let row = try cardReleaseRow(id: "pending", in: service)
        #expect(row.nextReviewDate == nil)
        #expect(row.introducedAt == nil)
    }

    private func newAssignmentTitles(in queue: StudyQueue) -> [String] {
        queue.entries.filter { $0.category == .newAssignment }.map(\.flashcard.frontText)
    }

    private func newCardTitles(in queue: StudyQueue) -> [String] {
        queue.entries.filter { $0.category == .newCard }.map(\.flashcard.frontText)
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
