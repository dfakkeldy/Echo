// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

struct ABSServerRecord: Codable, FetchableRecord, MutablePersistableRecord {
    var id: String
    var baseURL: String
    var username: String
    var defaultLibraryId: String?
    var addedAt: String

    static let databaseTableName = "abs_server"

    enum CodingKeys: String, CodingKey {
        case id, username
        case baseURL = "base_url"
        case defaultLibraryId = "default_library_id"
        case addedAt = "added_at"
    }

    var isPlainHTTP: Bool {
        URL(string: baseURL)?.scheme?.localizedCaseInsensitiveCompare("http") == .orderedSame
    }
}

struct ABSServerDAO {
    let db: DatabaseWriter

    /// v1 connects to at most one server; `current` returns it (or nil).
    func current() throws -> ABSServerRecord? {
        try db.read { db in try ABSServerRecord.fetchOne(db) }
    }

    func save(_ server: ABSServerRecord) throws {
        var copy = server
        try db.write { db in try copy.save(db) }
    }

    func delete(_ id: String) throws {
        _ = try db.write { db in try ABSServerRecord.deleteOne(db, key: id) }
    }
}
