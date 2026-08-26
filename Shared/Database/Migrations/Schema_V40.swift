// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

/// V40 — origin and advisory evidence for generated-narration quality issues.
/// Existing ASR rows retain their prior meaning through the default origin.
enum Schema_V40 {
    nonisolated static func migrate(_ db: Database) throws {
        try db.alter(table: NarrationQualityIssueRecord.databaseTableName) { table in
            table.add(column: "origin", .text).notNull().defaults(to: NarrationQualityIssueOrigin.asr.rawValue)
            table.add(column: "evidence_json", .text)
        }
        try db.create(
            index: "idx_narration_quality_issue_book_origin_status",
            on: NarrationQualityIssueRecord.databaseTableName,
            columns: ["audiobook_id", "origin", "status"],
            ifNotExists: true)
    }
}
