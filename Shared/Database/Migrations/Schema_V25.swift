// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

/// V25 - auto-generated flashcard study plans.
///
/// The plan controls first release of generated chapter/image assignments.
/// Existing `flashcard` rows remain the FSRS review unit after first grade.
enum Schema_V25 {
    nonisolated static func migrate(_ db: Database) throws {
        try db.create(table: "study_plan", ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("audiobook_id", .text).notNull()
                .references("audiobook", onDelete: .cascade)
            t.column("deck_id", .text)
                .references("deck", onDelete: .setNull)
            t.column("cadence_unit", .text).notNull().defaults(to: "day")
            t.column("new_chapter_limit", .integer).notNull().defaults(to: 1)
            t.column("include_images", .boolean).notNull().defaults(to: false)
            t.column("queue_mode_default", .text).notNull().defaults(to: "book_by_book")
            t.column("catch_up_policy", .text).notNull().defaults(to: "gentle")
            t.column("start_date", .text).notNull()
            t.column("is_paused", .boolean).notNull().defaults(to: false)
            t.column("created_at", .text).notNull()
            t.column("modified_at", .text).notNull()
        }

        try db.create(table: "study_plan_item", ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("plan_id", .text).notNull()
                .references("study_plan", onDelete: .cascade)
            t.column("flashcard_id", .text)
                .references("flashcard", onDelete: .setNull)
            t.column("kind", .text).notNull()
            t.column("chapter_index", .integer)
            t.column("source_block_id", .text)
                .references("epub_block", onDelete: .setNull)
            t.column("ordinal", .integer).notNull()
            t.column("introduced_at", .text)
            t.column("is_enabled", .boolean).notNull().defaults(to: true)
            t.column("created_at", .text).notNull()
            t.column("modified_at", .text).notNull()
        }

        try db.create(
            index: "idx_study_plan_book",
            on: "study_plan",
            columns: ["audiobook_id"],
            ifNotExists: true
        )
        try db.create(
            index: "idx_study_plan_active",
            on: "study_plan",
            columns: ["is_paused", "start_date"],
            ifNotExists: true
        )
        try db.create(
            index: "idx_study_plan_item_plan_order",
            on: "study_plan_item",
            columns: ["plan_id", "ordinal"],
            ifNotExists: true
        )
        try db.create(
            index: "idx_study_plan_item_pending",
            on: "study_plan_item",
            columns: ["plan_id", "is_enabled", "introduced_at"],
            ifNotExists: true
        )
        try db.create(
            index: "idx_study_plan_item_flashcard",
            on: "study_plan_item",
            columns: ["flashcard_id"],
            ifNotExists: true
        )
        try db.create(
            index: "idx_study_plan_item_source",
            on: "study_plan_item",
            columns: ["source_block_id"],
            ifNotExists: true
        )
    }
}
