import Foundation
import GRDB

/// DAO for persisted TOC entries — the publisher-declared chapter tree
/// resolved to imported EPUB blocks.
struct EPubTOCEntryDAO {
    let db: DatabaseWriter

    func insertAll(_ entries: [EPubTOCEntryRecord]) throws {
        guard !entries.isEmpty else { return }
        try db.write { db in
            for var entry in entries {
                try entry.insert(db)
            }
        }
    }

    func deleteAll(for audiobookID: String) throws {
        _ = try db.write { db in
            try EPubTOCEntryRecord
                .filter(Column("audiobook_id") == audiobookID)
                .deleteAll(db)
        }
    }

    /// All TOC entries for an audiobook in reading (preorder) sequence.
    func entries(for audiobookID: String) throws -> [EPubTOCEntryRecord] {
        try db.read { db in
            try EPubTOCEntryRecord
                .filter(Column("audiobook_id") == audiobookID)
                .order(Column("order_index"))
                .fetchAll(db)
        }
    }
}
