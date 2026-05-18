import GRDB

/// V3 migration — adds missing composite indexes on audiobook_id for tables
/// that were created in V1 but only received their audiobook indexes now.
enum Schema_V3 {
    static func migrate(_ db: Database) throws {
        try db.create(index: "idx_track_audiobook_sort", on: "track",
                       columns: ["audiobook_id", "sort_order"],
                       unique: false, ifNotExists: true)
        try db.create(index: "idx_chapter_audiobook_sort", on: "chapter",
                       columns: ["audiobook_id", "sort_order"],
                       unique: false, ifNotExists: true)
        try db.create(index: "idx_flashcard_audiobook_due", on: "flashcard",
                       columns: ["audiobook_id", "next_review_date"],
                       unique: false, ifNotExists: true)
        try db.create(index: "idx_planned_session_audiobook", on: "planned_session",
                       columns: ["audiobook_id", "start_time"],
                       unique: false, ifNotExists: true)
    }
}
