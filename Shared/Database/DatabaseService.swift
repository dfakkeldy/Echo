import Foundation
import GRDB
import os.log

enum DatabaseError: LocalizedError {
    case appGroupNotFound(String)

    var errorDescription: String? {
        switch self {
        case .appGroupNotFound(let identifier):
            return "App Group container not found for identifier: \(identifier). Check entitlements."
        }
    }
}

/// Owns a GRDB database in WAL mode (DatabasePool for disk, DatabaseQueue for in-memory).
@MainActor @Observable
final class DatabaseService {
    let writer: DatabaseWriter
    let dbPath: String
    private let logger = Logger(category: "DatabaseService")

    @ObservationIgnored private let migrationFlag = "sql_migration_done"
    @ObservationIgnored private let appGroupIdentifier: String

    init(appGroupIdentifier: String = "group.com.echo.audiobooks") throws {
        self.appGroupIdentifier = appGroupIdentifier
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw DatabaseError.appGroupNotFound(appGroupIdentifier)
        }

        try FileManager.default.createDirectory(
            at: containerURL,
            withIntermediateDirectories: true
        )

        let path = containerURL.appendingPathComponent("echo.sqlite").path
        self.dbPath = path

        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
            try db.execute(sql: "PRAGMA foreign_keys=ON")
        }
        writer = try DatabasePool(path: path, configuration: config)

        try runMigrations(writer: writer)
        logger.info("Database opened at \(path)")
    }

    init(inMemory: Void) throws {
        self.appGroupIdentifier = "inMemory"
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys=ON")
        }
        self.writer = try DatabaseQueue(path: ":memory:", configuration: config)
        self.dbPath = ":memory:"
        try runMigrations(writer: writer)
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

    private nonisolated func runMigrations(writer: DatabaseWriter) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_create_schema") { db in try Schema_V1.migrate(db) }
        migrator.registerMigration("v2_timeline_support") { db in try Schema_V2.migrate(db) }
        migrator.registerMigration("v3_missing_indexes") { db in try Schema_V3.migrate(db) }
        migrator.registerMigration("v4_materialized_timeline") { db in try Schema_V4.migrate(db) }
        migrator.registerMigration("v5_epub_alignment") { db in try Schema_V5.migrate(db) }
        migrator.registerMigration("v6_indexes_and_fixes") { db in try Schema_V6.migrate(db) }
        migrator.registerMigration("v7_epub_reader_columns") { db in try Schema_V7.migrate(db) }
        migrator.registerMigration("v8_epub_block_word_count") { db in try Schema_V8.migrate(db) }
        migrator.registerMigration("v9_epub_block_markers") { db in try Schema_V9.migrate(db) }
        migrator.registerMigration("v10_epub_block_chapter_theme") { db in try Schema_V10.migrate(db) }
        migrator.registerMigration("v11_bookmark_pdf_state") { db in try Schema_V11.migrate(db) }
        try migrator.migrate(writer)
    }

    // MARK: - UserDefaults migration flag

    /// Uses the App Group's shared UserDefaults so that extensions (widget,
    /// watch) see the same migration state as the main app. Storing the flag
    /// in `UserDefaults.standard` would cause duplicate migration attempts
    /// when an extension launches first.
    var isMigrationDone: Bool {
        get { UserDefaults(suiteName: appGroupIdentifier)?.bool(forKey: migrationFlag) ?? false }
        set { UserDefaults(suiteName: appGroupIdentifier)?.set(newValue, forKey: migrationFlag) }
    }
}
