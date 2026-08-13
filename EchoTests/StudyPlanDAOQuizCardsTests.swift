// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct StudyPlanDAOQuizCardsTests {
    @Test func returnsDueReleasedChapterCardsInOrdinalOrderCapped() throws {
        let service = try StudyQueueFixtures.serviceWithPlan()
        for index in 0..<6 {
            try StudyCardFixtures.seedAcceptedCard(
                id: "quiz-\(index)",
                chapterIndex: 0,
                ordinal: 100 + index,
                released: true,
                in: service
            )
        }

        let cards = try StudyPlanDAO(db: service.writer).dueQuizCards(
            audiobookID: "book-a",
            chapterIndex: 0,
            now: StudyQueueFixtures.mondayNoon,
            limit: 5
        )

        #expect(cards.map(\.id) == ["quiz-0", "quiz-1", "quiz-2", "quiz-3", "quiz-4"])
    }

    @Test func excludesUnreleasedOtherChapterAndFutureDueCards() throws {
        let service = try StudyQueueFixtures.serviceWithPlan()
        try StudyCardFixtures.seedAcceptedCard(
            id: "eligible", chapterIndex: 0, ordinal: 100, released: true, in: service)
        try StudyCardFixtures.seedAcceptedCard(
            id: "unreleased", chapterIndex: 0, ordinal: 101, in: service)
        try StudyCardFixtures.seedAcceptedCard(
            id: "other-chapter", chapterIndex: 1, ordinal: 102, released: true, in: service)
        try StudyCardFixtures.seedAcceptedCard(
            id: "future-due",
            chapterIndex: 0,
            ordinal: 103,
            released: true,
            releasedAt: StudyQueueFixtures.mondayNoon.addingTimeInterval(86_400),
            in: service
        )

        let cards = try StudyPlanDAO(db: service.writer).dueQuizCards(
            audiobookID: "book-a",
            chapterIndex: 0,
            now: StudyQueueFixtures.mondayNoon
        )

        #expect(cards.map(\.id) == ["eligible"])
    }

    @Test func pausedPlanYieldsNoQuizCards() throws {
        let service = try StudyQueueFixtures.serviceWithPlan()
        try StudyCardFixtures.seedAcceptedCard(
            id: "quiz-0", chapterIndex: 0, ordinal: 100, released: true, in: service)
        let dao = StudyPlanDAO(db: service.writer)
        let plan = try #require(try dao.plan(for: "book-a"))
        try dao.setPaused(planID: plan.id, isPaused: true, now: StudyQueueFixtures.mondayNoon)

        let cards = try dao.dueQuizCards(
            audiobookID: "book-a",
            chapterIndex: 0,
            now: StudyQueueFixtures.mondayNoon
        )

        #expect(cards.isEmpty)
    }

    @Test func pendingCardItemIDsExcludeDisabledOrOrphanedRows() throws {
        let service = try StudyQueueFixtures.serviceWithPlan()
        try StudyCardFixtures.seedAcceptedCard(
            id: "enabled", chapterIndex: 0, ordinal: 100, in: service)
        try StudyCardFixtures.seedAcceptedCard(
            id: "disabled", chapterIndex: 0, ordinal: 101, isEnabled: false, in: service)
        try StudyCardFixtures.seedAcceptedCard(
            id: "orphaned", chapterIndex: 0, ordinal: 102, in: service)
        let dao = StudyPlanDAO(db: service.writer)
        let plan = try #require(try dao.plan(for: "book-a"))
        try service.write { db in
            try db.execute(
                sql: "UPDATE study_plan_item SET flashcard_id = NULL WHERE id = 'item-orphaned'")
        }

        let itemIDs = try dao.pendingCardItemIDs(planID: plan.id, chapterIndex: 0, limit: 10)

        #expect(itemIDs == ["item-enabled"])
    }
}
