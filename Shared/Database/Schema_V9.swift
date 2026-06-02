import GRDB

/// V9 migration — adds markers and text_formats columns to epub_block
/// for storing SyncMarker and TextFormat data extracted during EPUB parsing.
enum Schema_V9 {
    static func migrate(_ db: Database) throws {
        try db.alter(table: "epub_block") { t in
            t.add(column: "markers", .text)
            t.add(column: "text_formats", .text)
        }
    }
}
