// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB
import Testing

@testable import Echo

@MainActor @Suite struct SchemaV34Tests {
    @Test func migrationCreatesAutoExportTables() throws {
        let db = try DatabaseService(inMemory: ())
        try db.writer.read { db in
            let destinationExists = try db.tableExists("study_export_destination")
            let stateExists = try db.tableExists("study_export_state")
            let destinationColumns = try db.columns(in: "study_export_destination").map(\.name)
            let stateColumns = try db.columns(in: "study_export_state").map(\.name)

            #expect(destinationExists)
            #expect(stateExists)
            #expect(destinationColumns.contains("bookmark"))
            #expect(stateColumns.contains("dirty"))
        }
    }

    @Test func destinationTableAllowsOnlyTheDefaultRow() throws {
        let db = try DatabaseService(inMemory: ())
        try db.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO study_export_destination (id, bookmark, display_path, added_at)
                    VALUES ('default', x'00', '/x', '2026-07-02T00:00:00Z')
                    """)
        }
        #expect(throws: (any Error).self) {
            try db.writer.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO study_export_destination (id, bookmark, display_path, added_at)
                        VALUES ('second', x'00', '/y', '2026-07-02T00:00:00Z')
                        """)
            }
        }
    }
}
