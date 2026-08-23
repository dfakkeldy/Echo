// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

/// V9 migration — adds markers and text_formats columns to epub_block
/// for storing SyncMarker and TextFormat data extracted during EPUB parsing.
enum Schema_V9 {
    nonisolated static func migrate(_ db: Database) throws {
        try db.alter(table: "epub_block") { t in
            t.add(column: "markers", .text)
            t.add(column: "text_formats", .text)
        }
    }
}

/// V10 migration — adds chapter_theme_color to epub_block
/// for storing chapter-level themes set by the user on headings.
enum Schema_V10 {
    nonisolated static func migrate(_ db: Database) throws {
        try db.alter(table: "epub_block") { t in
            t.add(column: "chapter_theme_color", .text)
        }
    }
}
