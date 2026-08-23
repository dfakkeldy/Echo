// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

/// V22 — seed FSRS memory state (`stability`, `difficulty`) for legacy SM-2 cards.
///
/// One-time data migration. Every previously-reviewed card (`repetitions > 0`)
/// with no FSRS `stability` yet is seeded from its SM-2 state, so its next FSRS
/// review evolves the existing memory instead of restarting from a first review
/// (which would discard its history). Never-reviewed cards stay `nil` and seed
/// naturally on their first FSRS review. Idempotent: only touches rows where
/// `stability IS NULL`.
enum Schema_V22 {
    nonisolated static func migrate(_ db: Database) throws {
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT id, interval_days, ease_factor FROM flashcard
                WHERE repetitions > 0 AND stability IS NULL
                """)
        for row in rows {
            let id: String = row["id"]
            let intervalDays: Int = row["interval_days"]
            let easeFactor: Double = row["ease_factor"]
            let seed = FSRSMigration.seed(intervalDays: intervalDays, easeFactor: easeFactor)
            try db.execute(
                sql: "UPDATE flashcard SET stability = ?, difficulty = ? WHERE id = ?",
                arguments: [seed.stability, seed.difficulty, id])
        }
    }
}
