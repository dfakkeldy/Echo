// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct DatabaseServiceFileURLTests {
    @Test func opensFileURLRunsMigrationsAndReopensExistingRows() throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "echo-db-file-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let dbURL = folder.appending(path: "echo.sqlite")
        let first = try DatabaseService(databaseURL: dbURL)

        let hasNarrationQATable = try first.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM sqlite_master
                    WHERE type = 'table' AND name = 'narration_quality_issue'
                    """
            ) ?? 0
        }
        #expect(hasNarrationQATable == 1)

        try first.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES (?, ?, ?)",
                arguments: ["book-1", "Fixture", 12.0]
            )
        }

        let reopened = try DatabaseService(databaseURL: dbURL)
        let title = try reopened.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT title FROM audiobook WHERE id = ?",
                arguments: ["book-1"]
            )
        }
        #expect(title == "Fixture")
    }

    @Test func asyncLaunchOpensMigratedDatabaseAndPreservesExistingRows() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "echo-db-launch-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "echo.sqlite")
        let first = try await DatabaseService.openForLaunch(databaseURL: url)
        try first.write { db in
            try db.execute(
                sql:
                    "INSERT INTO audiobook (id, title, duration) VALUES ('launch-book', 'Fixture', 12)"
            )
        }

        let reopened = try await DatabaseService.openForLaunch(databaseURL: url)
        let title = try reopened.read { db in
            try String.fetchOne(db, sql: "SELECT title FROM audiobook WHERE id = 'launch-book'")
        }
        #expect(title == "Fixture")
        let indexes = try reopened.read { db in try db.indexes(on: "alignment_anchor") }
        #expect(indexes.contains { $0.columns == ["epub_block_id"] })
    }

    @Test func asyncLaunchReportsInvalidDatabaseWithoutReplacingIt() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "echo-db-invalid-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "echo.sqlite")
        let original = Data(repeating: 0x41, count: 4096)
        try original.write(to: url)

        await #expect(throws: (any Error).self) {
            _ = try await DatabaseService.openForLaunch(databaseURL: url)
        }
        let remaining = try Data(contentsOf: url)
        #expect(remaining == original)
    }

    @Test func cancelledLaunchDoesNotCreateDatabase() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "echo-db-cancelled-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "echo.sqlite")
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await DatabaseService.openForLaunch(databaseURL: url)
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

}
