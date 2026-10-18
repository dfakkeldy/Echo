// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
struct StudyPlanDAOCheckpointTests {
    @Test func introducedInProgressChapterIsCheckpointable() throws {
        let service = try StudyQueueFixtures.serviceWithPlan()
        let dao = StudyPlanDAO(db: service.writer)

        let assignment = try dao.checkpointAssignment(
            audiobookID: "book-a", chapterIndex: 0, now: StudyQueueFixtures.mondayNoon)

        #expect(assignment?.card.frontText == "Book A Chapter 1")
        #expect(assignment?.item.chapterIndex == 0)
    }

    @Test func unintroducedChapterIsNotCheckpointable() throws {
        let service = try StudyQueueFixtures.serviceWithPlan()
        let dao = StudyPlanDAO(db: service.writer)

        let assignment = try dao.checkpointAssignment(
            audiobookID: "book-a", chapterIndex: 2, now: StudyQueueFixtures.mondayNoon)

        #expect(assignment == nil)
    }

    @Test func pausedPlanSilencesCheckpoints() throws {
        let service = try StudyQueueFixtures.serviceWithPlan()
        let dao = StudyPlanDAO(db: service.writer)
        let plan = try #require(try dao.plan(for: "book-a"))
        try dao.setPaused(planID: plan.id, isPaused: true, now: StudyQueueFixtures.mondayNoon)

        let assignment = try dao.checkpointAssignment(
            audiobookID: "book-a", chapterIndex: 0, now: StudyQueueFixtures.mondayNoon)

        #expect(assignment == nil)
    }

    @Test func futureStartPlanSilencesCheckpoints() throws {
        let service = try StudyQueueFixtures.serviceWithPlan(startDaysBeforeNow: -1)
        let dao = StudyPlanDAO(db: service.writer)

        let assignment = try dao.checkpointAssignment(
            audiobookID: "book-a", chapterIndex: 0, now: StudyQueueFixtures.mondayNoon)

        #expect(assignment == nil)
    }

    @Test func disabledItemIsNotCheckpointable() throws {
        let service = try StudyQueueFixtures.serviceWithPlan()
        let dao = StudyPlanDAO(db: service.writer)
        let plan = try #require(try dao.plan(for: "book-a"))
        let item = try #require(try dao.items(for: plan.id).first { $0.chapterIndex == 0 })
        try dao.setItemEnabled(itemID: item.id, isEnabled: false, now: StudyQueueFixtures.mondayNoon)

        let assignment = try dao.checkpointAssignment(
            audiobookID: "book-a", chapterIndex: 0, now: StudyQueueFixtures.mondayNoon)

        #expect(assignment == nil)
    }

    @Test func gradedFutureDueChapterIsNotCheckpointable() throws {
        let service = try StudyQueueFixtures.serviceWithPlan()
        let dao = StudyPlanDAO(db: service.writer)
        let cardID = try #require(
            try service.read { db in
                try String.fetchOne(
                    db, sql: "SELECT id FROM flashcard WHERE front_text = 'Book A Chapter 1'")
            })
        try FlashcardDAO(db: service.writer).grade(
            cardID: cardID, grade: 3, now: StudyQueueFixtures.mondayNoon)

        let assignment = try dao.checkpointAssignment(
            audiobookID: "book-a", chapterIndex: 0, now: StudyQueueFixtures.mondayNoon)

        #expect(assignment == nil)
    }

    @Test func gradedChapterBecomesCheckpointableAgainWhenDue() throws {
        let service = try StudyQueueFixtures.serviceWithPlan()
        let dao = StudyPlanDAO(db: service.writer)
        let cardID = try #require(
            try service.read { db in
                try String.fetchOne(
                    db, sql: "SELECT id FROM flashcard WHERE front_text = 'Book A Chapter 1'")
            })
        try FlashcardDAO(db: service.writer).grade(
            cardID: cardID,
            grade: 3,
            now: StudyQueueFixtures.mondayNoon.addingTimeInterval(-30 * 86_400)
        )

        let assignment = try dao.checkpointAssignment(
            audiobookID: "book-a", chapterIndex: 0, now: StudyQueueFixtures.mondayNoon)

        #expect(assignment?.card.id == cardID)
    }
}
