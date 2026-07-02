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

    init(
        appGroupIdentifier: String = AppGroupDefaults.suiteName,
        appGroupFallbackDirectory: URL? = DatabaseServiceAppGroupFallback.defaultDirectory,
        allowAppGroupFallback: Bool = DatabaseServiceAppGroupFallback.isAllowed
    ) throws {
        let containerURL: URL
        if let appGroupURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) {
            containerURL = appGroupURL
        } else if DatabaseServiceAppGroupFallback.isAllowed, allowAppGroupFallback,
            let appGroupFallbackDirectory
        {
            containerURL = appGroupFallbackDirectory
            Logger(category: "DatabaseService").warning(
                "Using debug simulator database fallback because App Group container is unavailable."
            )
        } else {
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

    init(databaseURL: URL) throws {
        if let parent = databaseURL.parentDirectory {
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true
            )
        }

        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode=WAL")
            try db.execute(sql: "PRAGMA foreign_keys=ON")
        }
        let path = databaseURL.path
        self.writer = try DatabasePool(path: path, configuration: config)
        self.dbPath = path
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

    // `T: Sendable` because GRDB's async `read`/`write` return the value across the
    // database access pool's executor boundary; Swift 6 requires the result to be
    // Sendable for that hop. (The synchronous variants above stay on the caller.)
    func readAsync<T: Sendable>(_ block: @escaping @Sendable (Database) throws -> T) async throws
        -> T
    {
        try await writer.read(block)
    }

    func write<T>(_ block: @escaping (Database) throws -> T) throws -> T {
        try writer.write(block)
    }

    func writeAsync<T: Sendable>(_ block: @escaping @Sendable (Database) throws -> T) async throws
        -> T
    {
        try await writer.write(block)
    }

    // MARK: - Migrations

    private nonisolated func runMigrations(writer: DatabaseWriter) throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_create_schema") { db in try Schema_V1.migrate(db) }
        migrator.registerMigration("v25_study_plans") { db in
            try Schema_V25.migrate(db)
        }
        migrator.registerMigration("v26_timeline_segment_key") { db in
            try Schema_V26.migrate(db)
        }
        migrator.registerMigration("v27_library") { db in
            try Schema_V27.migrate(db)
        }
        migrator.registerMigration("v28_pdf_block_page") { db in
            try Schema_V28.migrate(db)
        }
        migrator.registerMigration("v29_audiobook_text_origin") { db in
            try Schema_V29.migrate(db)
        }
        migrator.registerMigration("v30_narration_quality_issue") { db in
            try Schema_V30.migrate(db)
        }
        migrator.registerMigration("v31_abs_server_multi") { db in
            try Schema_V31.migrate(db)
        }
        migrator.registerMigration("v32_narration_text") { db in
            try Schema_V32.migrate(db)
        }
        migrator.registerMigration("v33_study_plan_card_pacing") { db in
            try Schema_V33.migrate(db)
        }
        try migrator.migrate(writer)
    }
}

extension URL {
    fileprivate var parentDirectory: URL? {
        guard !path.isEmpty else { return nil }
        return deletingLastPathComponent()
    }
}

private enum DatabaseServiceAppGroupFallback {
    #if DEBUG && targetEnvironment(simulator)
        static var isAllowed: Bool { true }
        static var defaultDirectory: URL? {
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first?
            .appending(path: "Echo", directoryHint: .isDirectory)
            .appending(path: "DebugAppGroupFallback", directoryHint: .isDirectory)
        }
    #else
        static var isAllowed: Bool { false }
        static var defaultDirectory: URL? { nil }
    #endif
}
