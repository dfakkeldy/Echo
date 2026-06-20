// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct FlashcardDAOSchedulerTests {
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    /// A "mature" card (8 reps) with no FSRS state. Under the old `repetitions >= 6`
    /// hybrid this ran SM-2 and left `stability` nil; the default scheduler must now
    /// be FSRS, which seeds memory state. `stability != nil` is the discriminator
    /// (SM-2 never writes stability).
    @Test func gradeWithDefaultScheduler_usesFSRS_seedsMemoryState() throws {
        let service = try DatabaseService(inMemory: ())
        let dao = FlashcardDAO(db: service.writer)
        try seedAudiobook(in: service)
        try dao.insert(makeCard(id: "c1", repetitions: 8, intervalDays: 30))

        try dao.grade(cardID: "c1", grade: 3, now: now)  // default scheduler

        let updated = try service.read { try Flashcard.fetchOne($0, key: "c1") }
        #expect(updated?.stability != nil)
        #expect(updated?.repetitions == 9)
    }

    /// Inserts the `audiobook` parent row the `flashcard.audiobook_id` foreign key
    /// requires (mirrors `RealTimeEventIntegrityTests`).
    private func seedAudiobook(in service: DatabaseService) throws {
        try service.write { db in
            try db.execute(sql: """
                INSERT INTO audiobook (id, title, duration, added_at)
                VALUES ('book', 'Test Audiobook', 3600, '2026-06-01T00:00:00Z')
                """)
        }
    }

    private func makeCard(id: String, repetitions: Int, intervalDays: Int) -> Flashcard {
        let stamp = now.ISO8601Format()
        return Flashcard(
            id: id, audiobookID: "book", frontText: "F", backText: "B",
            mediaTimestamp: 0, endTimestamp: nil, triggerTiming: .manualOnly,
            nextReviewDate: nil, intervalDays: intervalDays, easeFactor: 2.5,
            repetitions: repetitions, lastReviewedAt: nil, lastGrade: nil,
            isEnabled: true, deckID: nil, tags: nil, mediaJSON: nil,
            sourceBlockID: nil, playlistPosition: nil, createdAt: stamp, modifiedAt: stamp,
            stability: nil, difficulty: nil, cardType: "normal", clozeIndex: nil)
    }
}
