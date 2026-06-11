import GRDB

/// V13 migration — adds the `epub_toc_entry` table persisting the publisher's
/// hierarchical TOC (NCX navPoint / EPUB 3 nav nesting), resolved to blocks at
/// import. Replaces heading-derived TOC inference for books that declare one.
enum Schema_V13 {
    nonisolated static func migrate(_ db: Database) throws {
        try db.create(table: "epub_toc_entry") { t in
            t.column("id", .text).primaryKey()
            t.column("audiobook_id", .text).notNull()
                .references("audiobook", onDelete: .cascade)
            t.column("parent_id", .text)
            t.column("order_index", .integer).notNull()
            t.column("depth", .integer).notNull()
            t.column("title", .text).notNull()
            t.column("block_id", .text)
            t.column("spine_index", .integer)
        }
        try db.create(
            index: "idx_epub_toc_entry_book",
            on: "epub_toc_entry",
            columns: ["audiobook_id", "order_index"]
        )
    }
}
