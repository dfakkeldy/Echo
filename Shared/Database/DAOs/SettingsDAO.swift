import Foundation
import GRDB

struct SettingsDAO {
    let db: DatabaseWriter

    func get(_ key: String) throws -> String? {
        try db.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM settings WHERE key = ?", arguments: [key])
        }
    }

    func set(_ key: String, value: String) throws {
        try db.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO settings (key, value) VALUES (?, ?)",
                arguments: [key, value]
            )
        }
    }

    func getAll() throws -> [String: String] {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT key, value FROM settings")
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["key"], $0["value"]) })
        }
    }
}
