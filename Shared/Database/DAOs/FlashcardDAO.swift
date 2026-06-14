import Foundation
import GRDB

nonisolated struct FlashcardDAO {
    let db: DatabaseWriter

    func flashcards(for audiobookID: String) throws -> [Flashcard] {
        try db.read { db in
            try Flashcard
                .filter(Column("audiobook_id") == audiobookID)
                .fetchAll(db)
        }
    }

    func dueCards(for audiobookID: String) throws -> [Flashcard] {
        try db.read { db in
            try Flashcard
                .filter(Column("audiobook_id") == audiobookID)
                .filter(Column("next_review_date") <= Date().ISO8601Format())
                .order(Column("next_review_date"))
                .fetchAll(db)
        }
    }

    /// Statistics for the SRS dashboard.
    struct ReviewStats {
        var dueCount: Int
        var reviewedToday: Int
        var totalCards: Int
        /// Approximate retention rate (0–1) based on last-grade snapshot.
        var retentionRate: Double {
            totalCards > 0 ? Double(totalCards - dueCount) / Double(totalCards) : 0
        }
    }

    func reviewStats() throws -> ReviewStats {
        try db.read { db in
            let due =
                try Flashcard
                .filter(Column("next_review_date") <= Date().ISO8601Format())
                .fetchCount(db)
            let today = Date().ISO8601Format().prefix(10)  // YYYY-MM-DD
            let reviewed =
                try Flashcard
                .filter(Column("last_reviewed_at") >= "\(today)T00:00:00")
                .fetchCount(db)
            let total = try Flashcard.fetchCount(db)
            return ReviewStats(dueCount: due, reviewedToday: reviewed, totalCards: total)
        }
    }

    func allDueCards() throws -> [Flashcard] {
        try db.read { db in
            try Flashcard
                .filter(Column("next_review_date") <= Date().ISO8601Format())
                .order(Column("next_review_date"))
                .fetchAll(db)
        }
    }

    func insert(_ card: Flashcard) throws {
        var copy = card
        try db.write { db in
            try copy.insert(db)
            try syncToTimeline(db, card: copy)
        }
    }

    func update(_ card: Flashcard) throws {
        let copy = card
        try db.write { db in
            try copy.update(db)
            try syncToTimeline(db, card: copy)
        }
    }

    func grade(
        cardID: String, grade: Int, now: Date = Date(),
        scheduler: some SchedulingAlgorithm = SM2Scheduler()
    ) throws {
        try db.write { db in
            guard let card = try Flashcard.fetchOne(db, key: cardID) else { return }
            let updated = scheduler.review(card: card, grade: grade, now: now)
            try updated.update(db)
            try syncToTimeline(db, card: updated)
        }
    }

    private func syncToTimeline(_ db: Database, card: Flashcard) throws {
        let item = TimelineItem(
            id: "ankiCard-\(card.id)",
            audiobookID: card.audiobookID,
            itemType: .ankiCard,
            title: card.frontText,
            subtitle: card.backText,
            textPayload: nil,
            imagePath: nil,
            audioStartTime: card.mediaTimestamp,
            audioEndTime: card.endTimestamp,
            epubSequenceIndex: nil,
            granularityLevel: .sentence,
            playlistPosition: card.playlistPosition,
            isEnabled: card.isEnabled,
            sourceTable: "flashcard",
            sourceRowid: card.id,
            metadataJSON: encodeSM2(card),
            createdAt: nil,
            modifiedAt: nil
        )
        var mutable = item
        try mutable.save(db)
    }

    private func encodeSM2(_ card: Flashcard) -> String? {
        let dict: [String: Any] = [
            "nextReviewDate": card.nextReviewDate as Any,
            "intervalDays": card.intervalDays,
            "easeFactor": card.easeFactor,
            "repetitions": card.repetitions,
            "lastGrade": card.lastGrade as Any,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
            let json = String(data: data, encoding: .utf8)
        else { return nil }
        return json
    }
}
