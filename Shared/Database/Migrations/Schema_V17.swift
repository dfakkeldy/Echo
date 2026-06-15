import GRDB

enum Schema_V17 {
    nonisolated static func migrate(_ db: Database) throws {
        // Narration: record which TTS voice rendered each track (chapter).
        // Non-null marks a synthesized track; enables forward-only voice changes.
        try db.alter(table: "track") { t in
            t.add(column: "narration_voice", .text)
        }
    }
}
