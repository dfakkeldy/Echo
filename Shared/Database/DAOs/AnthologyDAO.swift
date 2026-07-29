// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

enum AnthologyDAOError: Error, Equatable {
    case anthologyNotFound
    case invalidEntryOrder
}

nonisolated struct AnthologyDAO {
    private let db: DatabaseWriter

    init(db: DatabaseWriter) {
        self.db = db
    }

    func save(_ anthology: AnthologyRecord) throws {
        var anthology = anthology
        try db.write { db in
            _ = try anthology.upsertAndFetch(
                db,
                onConflict: ["id"],
                updating: .noColumnUnlessSpecified,
                doUpdate: { excluded in
                    [
                        Column("title").set(to: excluded[Column("title")]),
                        Column("subtitle").set(to: excluded[Column("subtitle")]),
                        Column("creator").set(to: excluded[Column("creator")]),
                        Column("cover_path").set(to: excluded[Column("cover_path")]),
                        Column("modified_at").set(to: excluded[Column("modified_at")]),
                    ]
                }
            )
        }
    }

    func anthology(id: String) throws -> AnthologyRecord? {
        try db.read { db in
            try AnthologyRecord.fetchOne(db, key: id)
        }
    }

    func all() throws -> [AnthologyRecord] {
        try db.read { db in
            try AnthologyRecord.order(Column("created_at").desc, Column("id")).fetchAll(db)
        }
    }

    func addCapture(_ captureID: String, to anthologyID: String) throws -> AnthologyEntryRecord {
        try db.write { db in
            guard let stableSlot = try Int.fetchOne(
                db,
                sql: "SELECT next_stable_slot FROM anthology WHERE id = ?",
                arguments: [anthologyID]
            ) else {
                throw AnthologyDAOError.anthologyNotFound
            }
            let sortOrder = try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(sort_order), -1) + 1 FROM anthology_entry WHERE anthology_id = ?",
                arguments: [anthologyID]
            ) ?? 0
            var entry = AnthologyEntryRecord(
                id: UUID().uuidString,
                anthologyID: anthologyID,
                captureID: captureID,
                sortOrder: sortOrder,
                stableSlot: stableSlot,
                chapterTitleOverride: nil,
                narrationVoiceID: nil
            )
            try entry.insert(db)
            try db.execute(
                sql: "UPDATE anthology SET next_stable_slot = ? WHERE id = ?",
                arguments: [stableSlot + 1, anthologyID]
            )
            return entry
        }
    }

    func replaceOrder(anthologyID: String, entryIDs: [String]) throws {
        try db.write { db in
            let entries = try AnthologyEntryRecord
                .filter(Column("anthology_id") == anthologyID)
                .fetchAll(db)
            guard entries.count == entryIDs.count,
                Set(entries.map(\.id)) == Set(entryIDs),
                Set(entryIDs).count == entryIDs.count
            else {
                throw AnthologyDAOError.invalidEntryOrder
            }
            for (sortOrder, entryID) in entryIDs.enumerated() {
                try db.execute(
                    sql: "UPDATE anthology_entry SET sort_order = ? WHERE id = ? AND anthology_id = ?",
                    arguments: [sortOrder, entryID, anthologyID]
                )
            }
        }
    }

    func entries(anthologyID: String) throws -> [AnthologyEntryRecord] {
        try db.read { db in
            try AnthologyEntryRecord
                .filter(Column("anthology_id") == anthologyID)
                .order(Column("sort_order"), Column("stable_slot"), Column("id"))
                .fetchAll(db)
        }
    }

    func removeEntry(id: String) throws {
        _ = try db.write { db in
            try AnthologyEntryRecord.deleteOne(db, key: id)
        }
    }

    func saveBuild(_ build: AnthologyBuildRecord) throws {
        var build = build
        try db.write { db in
            try build.save(db)
            try db.execute(
                sql: """
                    UPDATE anthology
                    SET latest_build_revision = MAX(latest_build_revision, ?)
                    WHERE id = ?
                    """,
                arguments: [build.revision, build.anthologyID]
            )
        }
    }

    func latestSuccessfulBuild(anthologyID: String) throws -> AnthologyBuildRecord? {
        try db.read { db in
            try AnthologyBuildRecord.fetchOne(
                db,
                sql: """
                    SELECT * FROM anthology_build
                    WHERE anthology_id = ? AND status = 'succeeded'
                    ORDER BY revision DESC
                    LIMIT 1
                    """,
                arguments: [anthologyID]
            )
        }
    }

    func referencingAnthologies(captureID: String) throws -> [AnthologyRecord] {
        try db.read { db in
            try AnthologyRecord.fetchAll(
                db,
                sql: """
                    SELECT anthology.*
                    FROM anthology
                    JOIN anthology_entry ON anthology_entry.anthology_id = anthology.id
                    WHERE anthology_entry.capture_id = ?
                    ORDER BY anthology.created_at DESC, anthology.id
                    """,
                arguments: [captureID]
            )
        }
    }
}
