// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

struct ABSServerRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    var id: String
    var baseURL: String
    var username: String
    var defaultLibraryId: String?
    var addedAt: String
    var isActive: Bool = false

    static let databaseTableName = "abs_server"

    enum CodingKeys: String, CodingKey {
        case id, username
        case baseURL = "base_url"
        case defaultLibraryId = "default_library_id"
        case addedAt = "added_at"
        case isActive = "is_active"
    }

    var isPlainHTTP: Bool {
        URL(string: baseURL)?.scheme?.localizedCaseInsensitiveCompare("http") == .orderedSame
    }
}

/// Multiple servers can be saved (v2: `Schema_V31`); exactly one is active at
/// a time. `current()` returns the active row — iOS's single-server flow only
/// ever activates one, so its call sites are unaffected by the schema change.
struct ABSServerDAO {
    let db: DatabaseWriter

    /// The active server, if any.
    func current() throws -> ABSServerRecord? {
        try db.read { db in
            try ABSServerRecord.filter(Column("is_active") == true).fetchOne(db)
        }
    }

    /// Every saved server, most-recently-added first.
    func all() throws -> [ABSServerRecord] {
        try db.read { db in
            try ABSServerRecord.order(Column("added_at").desc).fetchAll(db)
        }
    }

    /// Insert-or-update by id. Does not change which server is active.
    func upsert(_ server: ABSServerRecord) throws {
        var copy = server
        try db.write { db in try copy.save(db) }
    }

    /// Marks `id` active and every other saved server inactive.
    func setActive(_ id: String) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE abs_server SET is_active = 0")
            try db.execute(sql: "UPDATE abs_server SET is_active = 1 WHERE id = ?", arguments: [id])
        }
    }

    func delete(_ id: String) throws {
        _ = try db.write { db in try ABSServerRecord.deleteOne(db, key: id) }
    }
}
