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
}
