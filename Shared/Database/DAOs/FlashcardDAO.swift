// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

nonisolated struct FlashcardDAO {
    let db: DatabaseWriter

    func count() throws -> Int {
        try db.read { try Flashcard.fetchCount($0) }
    }

    func flashcards(for audiobookID: String) throws -> [Flashcard] {
        try db.read { db in
            try Flashcard
                .filter(Column("audiobook_id") == audiobookID)
                .fetchAll(db)
        }
    }

    func dueCards(for audiobookID: String, now: Date = Date()) throws -> [Flashcard] {
        let nowString = now.ISO8601Format()
        return try db.read { db in
            try Flashcard
                .filter(Column("audiobook_id") == audiobookID)
                .filter(Column("is_enabled") == true)
                .filter(Column("next_review_date") != nil)
                .filter(Column("next_review_date") <= nowString)
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

    func reviewStats(now: Date = Date()) throws -> ReviewStats {
        let nowString = now.ISO8601Format()
        return try db.read { db in
            let scheduledEnabledCards =
                Flashcard
                .filter(Column("is_enabled") == true)
                .filter(Column("next_review_date") != nil)
            let due =
                try scheduledEnabledCards
                .filter(Column("next_review_date") <= nowString)
                .fetchCount(db)
            let today = nowString.prefix(10)  // YYYY-MM-DD
            let reviewed =
                try Flashcard
                .filter(Column("is_enabled") == true)
                .filter(Column("last_reviewed_at") >= "\(today)T00:00:00")
                .fetchCount(db)
            let total = try scheduledEnabledCards.fetchCount(db)
            return ReviewStats(dueCount: due, reviewedToday: reviewed, totalCards: total)
        }
    }

    func allDueCards(now: Date = Date()) throws -> [Flashcard] {
        let nowString = now.ISO8601Format()
        return try db.read { db in
            try Flashcard
                .filter(Column("is_enabled") == true)
                .filter(Column("next_review_date") != nil)
                .filter(Column("next_review_date") <= nowString)
                .order(Column("next_review_date"))
                .fetchAll(db)
        }
    }

    /// Existing vocabulary card for this book + word (case-insensitive), or nil.
    func vocabularyCard(for audiobookID: String, word: String) throws -> Flashcard? {
        try db.read { db in
            try Flashcard
                .filter(Column("audiobook_id") == audiobookID)
                .filter(Column("card_type") == StudyFlashcardType.vocabulary)
                .filter(sql: "LOWER(front_text) = ?", arguments: [word.lowercased()])
                .fetchOne(db)
        }
    }

    func insert(_ card: Flashcard) throws {
        try db.write { db in
            try Self.insert(card, in: db)
        }
    }

    func update(_ card: Flashcard) throws {
        let copy = card
        try db.write { db in
            try copy.update(db)
            try Self.syncToTimeline(db, card: copy)
        }
    }

    func grade(
        cardID: String, grade: Int, now: Date = Date(),
        scheduler: some SchedulingAlgorithm = FSRSScheduler()
    ) throws {
        try db.write { db in
            guard let card = try Flashcard.fetchOne(db, key: cardID) else { return }
            let updated = scheduler.review(card: card, grade: grade, now: now)
            try updated.update(db)
            try Self.syncToTimeline(db, card: updated)
        }
    }

    static func insert(_ card: Flashcard, in db: Database) throws {
        var copy = card
        try copy.insert(db)
        try syncToTimeline(db, card: copy)
    }

    private static func syncToTimeline(_ db: Database, card: Flashcard) throws {
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
            pdfViewStateJSON: nil,
            epubBlockID: card.sourceBlockID,
            segmentKey: nil,
            timestampSource: nil,
            alignmentStatus: nil,
            alignmentConfidence: nil,
            createdAt: nil,
            modifiedAt: nil
        )
        var mutable = item
        try mutable.save(db)
    }

    private static func encodeSM2(_ card: Flashcard) -> String? {
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
