import Foundation
import GRDB

struct AudiobookDAO {
    let db: DatabaseWriter

    func insert(_ audiobook: AudiobookRecord) throws {
        var copy = audiobook
        try db.write { db in try copy.insert(db) }
    }

    func save(_ audiobook: AudiobookRecord) throws {
        var copy = audiobook
        try db.write { db in try copy.save(db) }
    }

    func get(_ id: String) throws -> AudiobookRecord? {
        try db.read { db in try AudiobookRecord.fetchOne(db, key: id) }
    }

    func all() throws -> [AudiobookRecord] {
        try db.read { db in
            try AudiobookRecord
                .order(Column("added_at").desc)
                .fetchAll(db)
        }
    }

    /// Async variant for callers on the main actor (e.g. CarPlay connect) so the
    /// query runs on GRDB's pool rather than blocking the UI thread (audit §7.3).
    /// Named distinctly from `all()` so it doesn't shadow the sync overload at
    /// existing async call sites (which would then need `await`).
    func allAsync() async throws -> [AudiobookRecord] {
        try await db.read { db in
            try AudiobookRecord
                .order(Column("added_at").desc)
                .fetchAll(db)
        }
    }

    func delete(_ id: String) throws {
        _ = try db.write { db in
            try AudiobookRecord.deleteOne(db, key: id)
        }
    }
}

struct AudiobookRecord: Codable, FetchableRecord, MutablePersistableRecord {
    var id: String
    var title: String
    var author: String?
    var duration: TimeInterval
    var fileCount: Int?
    var addedAt: String

    static let databaseTableName = "audiobook"

    enum CodingKeys: String, CodingKey {
        case id, title, author, duration
        case fileCount = "file_count"
        case addedAt = "added_at"
    }
}
