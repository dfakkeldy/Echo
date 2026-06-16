// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
import Foundation
import GRDB
@testable import Echo

@MainActor
struct RealTimeEventIntegrityTests {

    @Test func testDailyReviewLogsCorrectFlashcardReviewedEvent() throws {
        // Setup in-memory database
        let dbService = try DatabaseService(inMemory: ())
        let dao = FlashcardDAO(db: dbService.writer)

        // Insert audiobook to satisfy foreign key constraints
        try dbService.write { db in
            try db.execute(sql: """
                INSERT INTO audiobook (id, title, duration, added_at)
                VALUES ('test_book', 'Test Audiobook', 3600, '2026-06-01T00:00:00Z')
                """)
        }

        // Insert a due flashcard
        let pastDate = Calendar.current.date(byAdding: .day, value: -1, to: Date())?.ISO8601Format() ?? ""
        let nowStr = Date().ISO8601Format()
        let card = Flashcard(
            id: "card_1",
            audiobookID: "test_book",
            frontText: "Front Text",
            backText: "Back Text",
            mediaTimestamp: 42.0,
            endTimestamp: 45.0,
            triggerTiming: .manualOnly,
            nextReviewDate: pastDate,
            intervalDays: 1,
            easeFactor: 2.5,
            repetitions: 0,
            isEnabled: true,
            createdAt: nowStr,
            modifiedAt: nowStr
        )
        try dao.insert(card)

        // Create viewModel and load due cards
        let viewModel = DailyReviewViewModel(db: dbService.writer, folderURL: nil)
        viewModel.loadDueCards()

        #expect(viewModel.dueCards.count == 1)
        #expect(viewModel.currentCard?.id == "card_1")

        // Grade card
        viewModel.gradeCard(5)

        // Fetch logged real-time event from database
        let events = try dbService.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM real_time_event WHERE event_type = 'flashcard_reviewed'")
        }

        #expect(events.count == 1)
        let event = events[0]
        #expect(event["event_type"] as? String == "flashcard_reviewed")
        #expect(event["audiobook_id"] as? String == "test_book")
        #expect(event["media_timestamp"] as? Double == 42.0)
        #expect(event["source_item_id"] as? String == "card_1")
        #expect(event["source_item_type"] as? String == "flashcard")

        // Ensure started_at and ended_at are non-null and match (representing closed instantaneous event)
        let startedAt = event["started_at"] as? String
        let endedAt = event["ended_at"] as? String
        #expect(startedAt != nil)
        #expect(endedAt != nil)
        #expect(startedAt == endedAt)
    }
}
