// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
struct StudyChapterRetireServiceTests {
    @Test func firstUserCardInAnActiveChapterPromptsExactlyOnce() throws {
        let service = try StudyQueueFixtures.serviceWithTwoPlansIncludingProgress()
        let retire = StudyChapterRetireService(db: service.writer)

        let prompt = try retire.promptForNewUserCard(
            audiobookID: "book-a",
            mediaTimestamp: 40,
            now: StudyQueueFixtures.mondayNoon
        )
        #expect(prompt?.chapterTitle == "Book A Chapter 1")

        let second = try retire.promptForNewUserCard(
            audiobookID: "book-a",
            mediaTimestamp: 60,
            now: StudyQueueFixtures.mondayNoon
        )
        #expect(second == nil)
    }

    @Test func cardOutsideAnyAssignmentRangeDoesNotPrompt() throws {
        let service = try StudyQueueFixtures.serviceWithTwoPlansIncludingProgress()
        let retire = StudyChapterRetireService(db: service.writer)

        let prompt = try retire.promptForNewUserCard(
            audiobookID: "book-a",
            mediaTimestamp: 5_000,
            now: StudyQueueFixtures.mondayNoon
        )
        #expect(prompt == nil)
    }

    @Test func pausedPlanDoesNotPrompt() throws {
        let service = try StudyQueueFixtures.serviceWithTwoPlansIncludingProgress()
        let dao = StudyPlanDAO(db: service.writer)
        let plan = try #require(try dao.plan(for: "book-a"))
        try dao.setPaused(planID: plan.id, isPaused: true, now: StudyQueueFixtures.mondayNoon)

        let prompt = try StudyChapterRetireService(db: service.writer).promptForNewUserCard(
            audiobookID: "book-a",
            mediaTimestamp: 40,
            now: StudyQueueFixtures.mondayNoon
        )
        #expect(prompt == nil)
    }

    @Test func retireDisablesTheAssignmentAndItIsReversible() throws {
        let service = try StudyQueueFixtures.serviceWithTwoPlansIncludingProgress()
        let retire = StudyChapterRetireService(db: service.writer)
        let prompt = try #require(
            try retire.promptForNewUserCard(
                audiobookID: "book-a",
                mediaTimestamp: 40,
                now: StudyQueueFixtures.mondayNoon))

        try retire.retire(
            assignmentCardID: prompt.assignmentCardID,
            assignmentItemID: prompt.assignmentItemID,
            now: StudyQueueFixtures.mondayNoon)

        let retired = try #require(
            try service.read { db in try Flashcard.fetchOne(db, key: prompt.assignmentCardID) })
        #expect(retired.isEnabled == false)

        let queueAfterRetire = try StudyQueueBuilder(db: service.writer).build(
            now: StudyQueueFixtures.mondayNoon,
            calendar: StudyQueueFixtures.calendar
        )
        #expect(!queueAfterRetire.entries.contains { $0.flashcard.id == prompt.assignmentCardID })

        try StudyPlanDAO(db: service.writer).setItemEnabled(
            itemID: prompt.assignmentItemID,
            isEnabled: true,
            now: StudyQueueFixtures.mondayNoon
        )
        let restored = try #require(
            try service.read { db in try Flashcard.fetchOne(db, key: prompt.assignmentCardID) })
        let queueAfterRestore = try StudyQueueBuilder(db: service.writer).build(
            now: StudyQueueFixtures.mondayNoon,
            calendar: StudyQueueFixtures.calendar
        )
        #expect(restored.isEnabled == true)
        #expect(queueAfterRestore.entries.contains { $0.flashcard.id == prompt.assignmentCardID })
    }

    @Test func legacyMediaJSONStillDecodesAfterTheFieldAddition() throws {
        let legacy = #"{"imagePath":"Images/one.png"}"#
        let decoded = try JSONDecoder().decode(
            StudyCardMedia.self,
            from: Data(legacy.utf8)
        )
        #expect(decoded.imagePath == "Images/one.png")
        #expect(decoded.retirePromptShownAt == nil)
    }

    @Test func pendingAICardsDeferManualRetirePromptUntilChapterDrains() throws {
        let service = try StudyQueueFixtures.serviceWithTwoPlansIncludingProgress()
        try StudyCardFixtures.seedAcceptedCard(
            id: "pending", chapterIndex: 0, ordinal: 100, in: service)
        let retire = StudyChapterRetireService(db: service.writer)

        let manualPrompt = try retire.promptForNewUserCard(
            audiobookID: "book-a",
            mediaTimestamp: 40,
            now: StudyQueueFixtures.mondayNoon
        )

        #expect(manualPrompt == nil)

        try StudyPlanDAO(db: service.writer).releaseCards(
            itemIDs: ["item-pending"], now: StudyQueueFixtures.mondayNoon)
        let drainedPrompt = try retire.promptForDrainedChapter(
            audiobookID: "book-a",
            chapterIndex: 0,
            now: StudyQueueFixtures.mondayNoon
        )

        #expect(drainedPrompt?.chapterTitle == "Book A Chapter 1")
        #expect(drainedPrompt?.coveringCardCount == 1)
    }
}
