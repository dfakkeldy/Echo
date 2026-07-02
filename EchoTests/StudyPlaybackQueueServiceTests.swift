// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
struct StudyPlaybackQueueServiceTests {
    private func cardID(frontText: String, in service: DatabaseService) throws -> String {
        try #require(
            try service.read { db in
                try String.fetchOne(
                    db,
                    sql: "SELECT id FROM flashcard WHERE front_text = ?",
                    arguments: [frontText]
                )
            })
    }

    @Test func walksTodaysQueueBookByBookAcrossBooks() throws {
        let service = try StudyQueueFixtures.serviceWithTwoPlansIncludingProgress()
        let queue = StudyPlaybackQueueService(db: service.writer)

        let first = try queue.nextPlayableItem(
            after: nil,
            now: StudyQueueFixtures.mondayNoon,
            calendar: StudyQueueFixtures.calendar
        )
        #expect(first.next?.title == "Book A Chapter 1")
        #expect(first.skippedUnplayable.isEmpty)

        let lastBookACard = try cardID(frontText: "Book A Chapter 2", in: service)
        let crossBook = try queue.nextPlayableItem(
            after: lastBookACard,
            now: StudyQueueFixtures.mondayNoon,
            calendar: StudyQueueFixtures.calendar
        )
        #expect(crossBook.next?.title == "Book B Chapter 1")
        #expect(crossBook.next?.audiobookID == "book-b")
    }

    @Test func endOfQueueReturnsNil() throws {
        let service = try StudyQueueFixtures.serviceWithTwoPlansIncludingProgress()
        let queue = StudyPlaybackQueueService(db: service.writer)
        let lastCard = try cardID(frontText: "Book B Chapter 2", in: service)

        let step = try queue.nextPlayableItem(
            after: lastCard,
            now: StudyQueueFixtures.mondayNoon,
            calendar: StudyQueueFixtures.calendar
        )

        #expect(step.next == nil)
    }

    @Test func unplayableItemsAreSurfacedNeverDropped() throws {
        let service = try StudyQueueFixtures.serviceWithTwoPlansIncludingProgress()
        let queue = StudyPlaybackQueueService(db: service.writer)

        let step = try queue.nextPlayableItem(
            after: nil,
            now: StudyQueueFixtures.mondayNoon,
            calendar: StudyQueueFixtures.calendar,
            isPlayable: { $0.audiobookID != "book-a" }
        )

        #expect(step.next?.audiobookID == "book-b")
        #expect(step.skippedUnplayable.count == 2)
        #expect(step.skippedUnplayable.allSatisfy { $0.audiobookID == "book-a" })
    }

    @Test func markSkippedDefersToTomorrowWithoutAGrade() throws {
        let service = try StudyQueueFixtures.serviceWithTwoPlansIncludingProgress()
        let queue = StudyPlaybackQueueService(db: service.writer)
        let id = try cardID(frontText: "Book A Chapter 1", in: service)

        try queue.markSkipped(
            flashcardID: id,
            now: StudyQueueFixtures.mondayNoon,
            calendar: StudyQueueFixtures.calendar
        )

        let card = try #require(
            try service.read { db in try Flashcard.fetchOne(db, key: id) })
        let tomorrow = try #require(
            StudyQueueFixtures.calendar.date(
                byAdding: .day,
                value: 1,
                to: StudyQueueFixtures.mondayNoon
            ))
        #expect(card.nextReviewDate == tomorrow.ISO8601Format())
        #expect(card.lastGrade == nil)
        #expect(card.repetitions == 0)

        let eventRow = try service.read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT metadata_json FROM real_time_event WHERE event_type = ?",
                arguments: [StudyCheckpointEventType.chapterSkipped]
            )
        }
        let metadataJSON: String? = eventRow?["metadata_json"]
        let metadata = FlashcardReviewMetadata.decode(metadataJSON)
        #expect(metadata?.skipped == true)
    }

    @Test func skipEligibilityRequiresNoUserCardsInChapter() throws {
        let service = try StudyQueueFixtures.serviceWithTwoPlansIncludingProgress()
        let queue = StudyPlaybackQueueService(db: service.writer)
        let assignmentID = try cardID(frontText: "Book A Chapter 1", in: service)

        #expect(try queue.isSkipEligible(assignmentCardID: assignmentID) == true)

        try StudyQueueFixtures.seedDueCard(
            id: "user-1",
            audiobookID: "book-a",
            frontText: "My card",
            nextReviewDate: StudyQueueFixtures.mondayNoon,
            isEnabled: true,
            in: service
        )
        #expect(try queue.isSkipEligible(assignmentCardID: assignmentID) == false)
    }

    @Test func userCardOutsideTheChapterRangeKeepsEligibility() throws {
        let service = try StudyQueueFixtures.serviceWithTwoPlansIncludingProgress()
        let queue = StudyPlaybackQueueService(db: service.writer)
        let assignmentID = try cardID(frontText: "Book A Chapter 1", in: service)

        try service.write { db in
            try db.execute(
                sql: """
                    INSERT INTO flashcard
                    (id, audiobook_id, front_text, back_text, media_timestamp, trigger_timing,
                     interval_days, ease_factor, repetitions, is_enabled)
                    VALUES ('user-2', 'book-a', 'Later card', 'Back', 150, 'manualOnly',
                            0, 2.5, 0, 1)
                    """)
        }

        #expect(try queue.isSkipEligible(assignmentCardID: assignmentID) == true)
    }

    @Test func needsAttentionRoundTrips() throws {
        let service = try StudyQueueFixtures.serviceWithTwoPlansIncludingProgress()
        let queue = StudyPlaybackQueueService(db: service.writer)
        let item = StudyPlayableItem(
            flashcardID: "card-x",
            audiobookID: "book-a",
            chapterIndex: 0,
            planItemID: nil,
            title: "Book A Chapter 1",
            startTime: 0,
            endTime: 100
        )

        try queue.markNeedsAttention(
            item: item,
            reason: "Book not downloaded",
            now: StudyQueueFixtures.mondayNoon
        )

        let ids = try queue.needsAttentionFlashcardIDs(
            now: StudyQueueFixtures.mondayNoon,
            calendar: StudyQueueFixtures.calendar
        )
        #expect(ids.contains("card-x"))
    }
}
