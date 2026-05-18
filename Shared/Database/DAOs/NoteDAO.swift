import Foundation
import GRDB

struct NoteDAO {
    let db: DatabaseWriter

    func notes(for audiobookID: String) throws -> [NoteRecord] {
        try db.read { db in
            try NoteRecord
                .filter(Column("audiobook_id") == audiobookID)
                .order(Column("media_timestamp"))
                .fetchAll(db)
        }
    }

    func notes(in timeRange: ClosedRange<TimeInterval>, audiobookID: String) throws -> [NoteRecord] {
        try db.read { db in
            try NoteRecord
                .filter(Column("audiobook_id") == audiobookID)
                .filter(Column("media_timestamp") >= timeRange.lowerBound && Column("media_timestamp") <= timeRange.upperBound)
                .order(Column("media_timestamp"))
                .fetchAll(db)
        }
    }

    func note(id: String) throws -> NoteRecord? {
        try db.read { db in try NoteRecord.fetchOne(db, key: id) }
    }

    func insert(_ note: NoteRecord) throws {
        var copy = note
        try db.write { db in try copy.insert(db) }
    }

    func update(_ note: NoteRecord) throws {
        var copy = note
        try db.write { db in try copy.save(db) }
    }

    func delete(id: String) throws {
        try db.write { db in try NoteRecord.deleteOne(db, key: id) }
    }

    func deleteAll(for audiobookID: String) throws {
        try db.write { db in
            try NoteRecord
                .filter(Column("audiobook_id") == audiobookID)
                .deleteAll(db)
        }
    }

    func count(for audiobookID: String) throws -> Int {
        try db.read { db in
            try NoteRecord
                .filter(Column("audiobook_id") == audiobookID)
                .fetchCount(db)
        }
    }
}
