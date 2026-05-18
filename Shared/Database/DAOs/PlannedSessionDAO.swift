import Foundation
import GRDB

struct PlannedSessionDAO {
    let db: DatabaseWriter

    func sessions(for audiobookID: String) throws -> [PlannedSessionRecord] {
        try db.read { db in
            try PlannedSessionRecord
                .filter(Column("audiobook_id") == audiobookID)
                .order(Column("start_time"))
                .fetchAll(db)
        }
    }

    func upcomingSessions(for audiobookID: String, after date: Date = Date()) throws -> [PlannedSessionRecord] {
        let iso = date.ISO8601Format()
        return try db.read { db in
            try PlannedSessionRecord
                .filter(Column("audiobook_id") == audiobookID)
                .filter(Column("start_time") >= iso)
                .order(Column("start_time"))
                .fetchAll(db)
        }
    }

    func sessions(in range: ClosedRange<Date>) throws -> [PlannedSessionRecord] {
        try db.read { db in
            try PlannedSessionRecord
                .filter(Column("start_time") >= range.lowerBound.ISO8601Format())
                .filter(Column("end_time") <= range.upperBound.ISO8601Format())
                .order(Column("start_time"))
                .fetchAll(db)
        }
    }

    func session(id: String) throws -> PlannedSessionRecord? {
        try db.read { db in try PlannedSessionRecord.fetchOne(db, key: id) }
    }

    func insert(_ session: PlannedSessionRecord) throws {
        var copy = session
        try db.write { db in try copy.insert(db) }
    }

    func update(_ session: PlannedSessionRecord) throws {
        var copy = session
        try db.write { db in try copy.save(db) }
    }

    func markCompleted(id: String) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE planned_session SET is_completed = 1 WHERE id = ?",
                arguments: [id]
            )
        }
    }

    func delete(id: String) throws {
        try db.write { db in try PlannedSessionRecord.deleteOne(db, key: id) }
    }

    func deleteAll(for audiobookID: String) throws {
        try db.write { db in
            try PlannedSessionRecord
                .filter(Column("audiobook_id") == audiobookID)
                .deleteAll(db)
        }
    }
}
