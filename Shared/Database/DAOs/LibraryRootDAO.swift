// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

/// A user-registered folder that the Library rescans for books. Stores the
/// security-scoped bookmark so the folder (and recursively its children) can be
/// reopened across launches.
struct LibraryRootRecord: Codable, FetchableRecord, MutablePersistableRecord {
    var id: String
    var displayName: String
    var bookmark: Data
    var addedAt: String
    var lastScannedAt: String?

    static let databaseTableName = "library_root"

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case bookmark
        case addedAt = "added_at"
        case lastScannedAt = "last_scanned_at"
    }
}

struct LibraryRootDAO {
    private let db: DatabaseWriter

    init(db: DatabaseWriter) {
        self.db = db
    }

    func all() throws -> [LibraryRootRecord] {
        try db.read { db in
            try LibraryRootRecord.order(Column("added_at").desc).fetchAll(db)
        }
    }

    func get(_ id: String) throws -> LibraryRootRecord? {
        try db.read { db in try LibraryRootRecord.fetchOne(db, key: id) }
    }

    func save(_ root: LibraryRootRecord) throws {
        var copy = root
        try db.write { db in try copy.save(db) }
    }

    func delete(id: String) throws {
        _ = try db.write { db in try LibraryRootRecord.deleteOne(db, key: id) }
    }
}
