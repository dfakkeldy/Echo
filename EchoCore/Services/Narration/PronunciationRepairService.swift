// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

/// Scope for a pronunciation fix: a specific book or the global dictionary.
enum FixScope: Equatable {
    case book(String)
    case global
}

/// Thrown when an issue carries no actionable pronunciation suggestion.
enum NarrationRepairError: Error, Equatable {
    case noUsableFix
}

/// Turns an accepted narration-QA fix into a pronunciation override, regenerates
/// the affected chapter, re-runs QA on it, and resolves the issue. Pure EchoCore
/// (no UIKit / no `PlayerModel`) so it bundles into iOS, macOS, and echo-cli
/// unchanged. Concrete-type + constructor injection (no protocol): there is one
/// implementation.
@MainActor
final class PronunciationRepairService {

    /// Resolve the `epub_block.chapter_index` for a block id. Used to scope
    /// regeneration to the single chapter that contains a flagged issue.
    static func chapterIndex(
        forBlockID blockID: String, audiobookID: String, db: DatabaseWriter
    ) throws -> Int? {
        try db.read { database in
            try Int.fetchOne(
                database,
                sql: """
                    SELECT chapter_index FROM epub_block
                    WHERE id = ? AND audiobook_id = ?
                    """,
                arguments: [blockID, audiobookID])
        }
    }
}
