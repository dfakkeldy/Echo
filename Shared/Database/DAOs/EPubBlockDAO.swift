import Foundation
import GRDB

/// DAO for EPUB block records — headings, paragraphs, sentences, and images
/// parsed from the EPUB spine and stored in structural reading order.
struct EPubBlockDAO {
    let db: DatabaseWriter

    // MARK: - Insert

    func insert(_ block: EPubBlockRecord) throws {
        var mutable = block
        try db.write { db in
            try mutable.insert(db)
        }
    }

    func insertAll(_ blocks: [EPubBlockRecord]) throws {
        guard !blocks.isEmpty else { return }
        try db.write { db in
            for var block in blocks {
                try block.insert(db)
            }
        }
    }

    // MARK: - Delete

    func deleteAll(for audiobookID: String) throws {
        _ = try db.write { db in
            try EPubBlockRecord
                .filter(Column("audiobook_id") == audiobookID)
                .deleteAll(db)
        }
    }

    // MARK: - Queries

    /// All blocks for an audiobook, ordered by reading sequence.
    func blocks(for audiobookID: String) throws -> [EPubBlockRecord] {
        try db.read { db in
            try EPubBlockRecord
                .filter(Column("audiobook_id") == audiobookID)
                .order(Column("sequence_index"))
                .fetchAll(db)
        }
    }

    /// Blocks in a specific chapter, ordered by sequence.
    func blocks(for audiobookID: String, chapterIndex: Int) throws -> [EPubBlockRecord] {
        try db.read { db in
            try EPubBlockRecord
                .filter(Column("audiobook_id") == audiobookID)
                .filter(Column("chapter_index") == chapterIndex)
                .order(Column("sequence_index"))
                .fetchAll(db)
        }
    }

    /// Visible blocks for feed display (excludes hidden).
    func visibleBlocks(for audiobookID: String) throws -> [EPubBlockRecord] {
        try db.read { db in
            try EPubBlockRecord
                .filter(Column("audiobook_id") == audiobookID)
                .filter(Column("is_hidden") == false)
                .order(Column("sequence_index"))
                .fetchAll(db)
        }
    }

    /// Search block text for matching terms. Escapes SQL LIKE wildcards
    /// in user input to prevent accidental or malicious pattern injection.
    func searchBlocks(for audiobookID: String, query: String) throws -> [EPubBlockRecord] {
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return try db.read { db in
            try EPubBlockRecord
                .filter(Column("audiobook_id") == audiobookID)
                .filter(Column("text").like("%\(escaped)%", escape: "\\"))
                .order(Column("sequence_index"))
                .fetchAll(db)
        }
    }

    // MARK: - Mutations

    func hideBlock(id: String, reason: String?) throws {
        try db.write { db in
            try db.execute(
                sql: """
                    UPDATE epub_block
                    SET is_hidden = 1, hidden_reason = :reason, modified_at = :now
                    WHERE id = :id
                    """,
                arguments: ["reason": reason, "now": ISO8601DateFormatter().string(from: Date()), "id": id]
            )
        }
    }

    func unhideBlock(id: String) throws {
        try db.write { db in
            try db.execute(
                sql: """
                    UPDATE epub_block
                    SET is_hidden = 0, hidden_reason = NULL, modified_at = :now
                    WHERE id = :id
                    """,
                arguments: ["now": ISO8601DateFormatter().string(from: Date()), "id": id]
            )
        }
    }
}
