// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import os.log

enum DatabaseError: LocalizedError {
    case appGroupNotFound(String)

    var errorDescription: String? {
        switch self {
        case .appGroupNotFound(let identifier):
            return
                "App Group container not found for identifier: \(identifier). Check entitlements."
        }
    }
}

/// Owns a GRDB database in WAL mode (DatabasePool for disk, DatabaseQueue for in-memory).
@MainActor @Observable
final class DatabaseService {
    let writer: DatabaseWriter
    let dbPath: String
    private let logger = Logger(category: "DatabaseService")

    init(appGroupIdentifier: String = AppGroupDefaults.suiteName) throws {
        guard
            let containerURL = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: appGroupIdentifier
            )
        else {
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
        try migrator.migrate(writer)
    }
}
