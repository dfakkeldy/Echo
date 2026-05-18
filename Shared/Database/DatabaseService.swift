import Foundation
import GRDB
import os.log

/// Owns the GRDB DatabasePool in WAL mode. Lives in the App Group container
/// so iOS, watchOS, macOS, and Widget targets all share the same database.
@Observable
final class DatabaseService {
    private let pool: DatabasePool
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
        pool = try DatabasePool(path: path, configuration: config)

        try runMigrations()
        logger.info("Database opened at \(path)")
    }

    init(inMemory: Void) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys=ON")
        }
        self.pool = try DatabasePool(path: ":memory:", configuration: config)
        self.dbPath = ":memory:"
        try runMigrations()
    }

    // MARK: - Accessors

    func read<T>(_ block: @escaping (Database) throws -> T) throws -> T {
        try pool.read(block)
    }

    func readAsync<T>(_ block: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await pool.read(block)
    }

    func write<T>(_ block: @escaping (Database) throws -> T) throws -> T {
        try pool.write(block)
    }

    func writeAsync<T>(_ block: @escaping @Sendable (Database) throws -> T) async throws -> T {
        try await pool.write(block)
    }

    var writer: DatabaseWriter { pool }

    // MARK: - Migrations

    private func runMigrations() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_create_schema") { db in
            try Schema_V1.migrate(db)
        }
        try migrator.migrate(pool)
    }

    // MARK: - UserDefaults migration flag

    var isMigrationDone: Bool {
        get { UserDefaults.standard.bool(forKey: migrationFlag) }
        set { UserDefaults.standard.set(newValue, forKey: migrationFlag) }
    }
}
