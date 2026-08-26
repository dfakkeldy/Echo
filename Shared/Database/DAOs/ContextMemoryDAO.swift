// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

struct ContextMemoryDeletionSummary: Equatable, Sendable {
    let bookmarkCount: Int
    let sessionLocationCount: Int
}

nonisolated struct ContextMemoryDAO {
    let db: DatabaseWriter

    func deleteAll() throws -> ContextMemoryDeletionSummary {
        try db.write { db in
            let bookmarkCount =
                try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*)
                        FROM bookmark
                        WHERE latitude IS NOT NULL
                           OR longitude IS NOT NULL
                           OR place_name IS NOT NULL
                        """
                ) ?? 0
            let sessionLocationCount =
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM session_location") ?? 0

            try db.execute(
                sql: """
                    UPDATE bookmark
                    SET latitude = NULL,
                        longitude = NULL,
                        place_name = NULL
                    WHERE latitude IS NOT NULL
                       OR longitude IS NOT NULL
                       OR place_name IS NOT NULL
                    """
            )
            try db.execute(sql: "DELETE FROM session_location")

            return ContextMemoryDeletionSummary(
                bookmarkCount: bookmarkCount,
                sessionLocationCount: sessionLocationCount
            )
        }
    }
}
