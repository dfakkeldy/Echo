import Foundation
import GRDB
import os.log

/// Owns a GRDB database in WAL mode (DatabasePool for disk, DatabaseQueue for in-memory).
@Observable
final class DatabaseService {
    let writer: DatabaseWriter
    let dbPath: String
    private let logger = Logger(subsystem: "com.orbitaudiobooks", category: "DatabaseService")

    @ObservationIgnored private let migrationFlag = "sql_migration_done"

    init(appGroupIdentifier: String = "group.com.orbitaudiobooks") throws {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            fatalError("App Group container not found. Check entitlements.")
        }

        try FileManager.default.createDirectory(
            at: containerURL,
            withIntermediateDirectories: true
        )

        let path = containerURL.appendingPathComponent("orbit.sqlite").path
        self.dbPath = path

        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
            try db.execute(sql: "PRAGMA foreign_keys=ON")
        }
        writer = try DatabasePool(path: path, configuration: config)

        try runMigrations()
        logger.info("Database opened at \(path)")
    }

    init(inMemory: Void) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys=ON")
        }
        self.writer = try DatabaseQueue(path: ":memory:", configuration: config)
        self.dbPath = ":memory:"
        try runMigrations()
    }

    // MARK: - Accessors

    func read<T>(_ block: @escaping (Database) throws -> T) throws -> T {
        try writer.read(block)
    }

    func readAsync<T>(_ block: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await writer.read(block)
    }

    func write<T>(_ block: @escaping (Database) throws -> T) throws -> T {
        try writer.write(block)
    }

    func writeAsync<T>(_ block: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await writer.write(block)
    }

    // MARK: - Migrations

    private func runMigrations() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_create_schema") { db in
            try Schema_V1.migrate(db)
        }
        migrator.registerMigration("v2_timeline_support") { db in
            try Schema_V2.migrate(db)
        }
        migrator.registerMigration("v3_missing_indexes") { db in
            try Schema_V3.migrate(db)
        }
        migrator.registerMigration("v4_materialized_timeline") { db in
            try Schema_V4.migrate(db)
        }
        try migrator.migrate(writer)
    }

    // MARK: - UserDefaults migration flag

    var isMigrationDone: Bool {
        get { UserDefaults.standard.bool(forKey: migrationFlag) }
        set { UserDefaults.standard.set(newValue, forKey: migrationFlag) }
    }
}
