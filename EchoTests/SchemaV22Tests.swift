// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct SchemaV22Tests {
    /// `DatabaseService(inMemory:)` already runs all migrations including V22, so we
    /// insert legacy-shaped cards *after* migration and invoke `Schema_V22.migrate`
    /// directly (it is idempotent — it only touches `stability IS NULL`).
    @Test func v22_seedsReviewedCard_andLeavesNeverReviewedCardNil() throws {
        let service = try DatabaseService(inMemory: ())
        let dao = FlashcardDAO(db: service.writer)
        try seedAudiobook(in: service)
        try dao.insert(makeCard(id: "old", repetitions: 4, intervalDays: 20, ease: 2.0))
        try dao.insert(makeCard(id: "new", repetitions: 0, intervalDays: 0, ease: 2.5))

        try service.write { try Schema_V22.migrate($0) }

        let old = try service.read { try Flashcard.fetchOne($0, key: "old") }
        let new = try service.read { try Flashcard.fetchOne($0, key: "new") }
        #expect(old?.stability == 20)
        #expect((old?.difficulty ?? 0) >= 1 && (old?.difficulty ?? 0) <= 10)
        #expect(new?.stability == nil)
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

    private func makeCard(id: String, repetitions: Int, intervalDays: Int, ease: Double)
        -> Flashcard
    {
        let stamp = Date(timeIntervalSince1970: 1_750_000_000).ISO8601Format()
        return Flashcard(
            id: id, audiobookID: "book", frontText: "F", backText: "B",
            mediaTimestamp: 0, endTimestamp: nil, triggerTiming: .manualOnly,
            nextReviewDate: nil, intervalDays: intervalDays, easeFactor: ease,
            repetitions: repetitions, lastReviewedAt: nil, lastGrade: nil,
            isEnabled: true, deckID: nil, tags: nil, mediaJSON: nil,
            sourceBlockID: nil, playlistPosition: nil, createdAt: stamp, modifiedAt: stamp,
            stability: nil, difficulty: nil, cardType: "normal", clozeIndex: nil)
    }
}
