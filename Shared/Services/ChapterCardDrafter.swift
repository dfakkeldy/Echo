import Foundation
import GRDB
import os.log

/// Generates one flashcard per chapter heading so new users have a deck
/// immediately after importing a book. Idempotent — re-running skips
/// headings that already have a card.
struct ChapterCardDrafter {
    enum DrafterError: LocalizedError {
        case headingQueryFailed(Error)
        case deckCreationFailed(Error)
        case cardInsertFailed(Error)

        var errorDescription: String? {
            switch self {
            case .headingQueryFailed(let e): "Heading query failed: \(e.localizedDescription)"
            case .deckCreationFailed(let e): "Deck creation failed: \(e.localizedDescription)"
            case .cardInsertFailed(let e): "Card insert failed: \(e.localizedDescription)"
            }
        }
    }

    /// Auto-draft chapter cards for a book. Returns the number of cards created.
    func draftCards(
        for audiobookID: String,
        bookTitle: String,
        db: DatabaseWriter
    ) async throws -> Int {
        // 1. Query heading blocks — exclude front matter and junk headings
        let headings: [Row]
        do {
            headings = try await db.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT id, text, chapter_index
                    FROM epub_block
                    WHERE audiobook_id = ?
                      AND block_kind = 'heading'
                      AND is_front_matter = 0
                    ORDER BY sequence_index
                    """, arguments: [audiobookID])
            }
        } catch {
            throw DrafterError.headingQueryFailed(error)
        }

        guard !headings.isEmpty else { return 0 }

        // 2. Find or create the book's deck
        let deckID: String
        do {
            deckID = try await findOrCreateDeck(named: bookTitle, db: db)
        } catch {
            throw DrafterError.deckCreationFailed(error)
        }

        // 3. Create cards for each heading (skip if already exists)
        var created = 0
        for heading in headings {
            let headingID: String = heading["id"]
            let headingText: String = heading["text"] ?? "Untitled"
            let chapterIndex: Int = heading["chapter_index"] ?? 0

            // Idempotency: skip if card already exists for this heading
            let exists = (try? await db.read { db in
                try Flashcard
                    .filter(Column("source_block_id") == headingID)
                    .filter(Column("card_type") == "normal")
                    .fetchCount(db) > 0
            }) ?? false
            guard !exists else { continue }

            var card = Flashcard(
                id: UUID().uuidString,
                audiobookID: audiobookID,
                frontText: headingText,
                backText: "Chapter \(chapterIndex + 1) — \(bookTitle)",
                mediaTimestamp: 0,
                endTimestamp: nil,
                triggerTiming: .manualOnly,
                nextReviewDate: nil,
                intervalDays: 0,
                easeFactor: 2.5,
                repetitions: 0,
                lastReviewedAt: nil,
                lastGrade: nil,
                isEnabled: true,
                deckID: deckID,
                tags: "auto-drafted chapter",
                mediaJSON: nil,
                sourceBlockID: headingID,
                playlistPosition: nil,
                createdAt: Date().ISO8601Format(),
                modifiedAt: Date().ISO8601Format()
            )

            do {
                try await db.write { db in try card.insert(db) }
                created += 1
            } catch {
                // Log and continue — one failed insert should not abort the batch
                Logger(category: "ChapterCardDrafter").error(
                    "Failed to insert card for heading \(headingID): \(error.localizedDescription)"
                )
            }
        }

        return created
    }

    private func findOrCreateDeck(named name: String, db: DatabaseWriter) async throws -> String {
        // Check if deck exists
        if let existing = try await db.read({ db in
            try Row.fetchOne(db, sql: "SELECT id FROM deck WHERE name = ?", arguments: [name])
        }) {
            return existing["id"]
        }

        // Create new deck
        let id = UUID().uuidString
        let now = Date().ISO8601Format()
        try await db.write { db in
            try db.execute(sql: """
                INSERT INTO deck (id, name, source, created_at, modified_at)
                VALUES (?, ?, 'auto', ?, ?)
                """, arguments: [id, name, now, now])
        }
        return id
    }
}
