// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

enum AnthologyDAOError: Error, Equatable {
    case anthologyNotFound
    case captureNotFound(String)
    case entryNotFound
    case invalidEntryOrder
    case revisionConflict
}

nonisolated struct AnthologyDatabaseEntrySnapshot: Equatable, Sendable {
    let entry: AnthologyEntryRecord
    let capture: ArticleCaptureRecord
    let revision: ArticleRevisionRecord?
}

nonisolated struct AnthologyDatabaseSnapshot: Equatable, Sendable {
    let anthology: AnthologyRecord
    let entries: [AnthologyDatabaseEntrySnapshot]
    let latestSuccessfulBuild: AnthologyBuildRecord?
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

    func create(
        _ anthology: AnthologyRecord,
        captureIDs: [String],
        makeEntryID: @Sendable () -> UUID = UUID.init
    ) throws -> AnthologyRecord {
        try db.write { db in
            var created = anthology
            created.nextStableSlot = captureIDs.count
            try created.insert(db)

            for (position, captureID) in captureIDs.enumerated() {
                guard try ArticleCaptureRecord.fetchOne(db, key: captureID) != nil else {
                    throw AnthologyDAOError.captureNotFound(captureID)
                }
                var entry = AnthologyEntryRecord(
                    id: makeEntryID().uuidString,
                    anthologyID: created.id,
                    captureID: captureID,
                    sortOrder: position,
                    stableSlot: position,
                    chapterTitleOverride: nil,
                    narrationVoiceID: nil
                )
                try entry.insert(db)
            }
            return created
        }
    }

    func addCapture(
        _ captureID: String,
        to anthologyID: String,
        modifiedAt: String? = nil,
        makeEntryID: @Sendable () -> UUID = UUID.init
    ) throws -> AnthologyEntryRecord {
        guard
            let entry = try addCaptures(
                [captureID],
                to: anthologyID,
                modifiedAt: modifiedAt,
                makeEntryID: makeEntryID
            ).first
        else {
            throw AnthologyDAOError.invalidEntryOrder
        }
        return entry
    }

    func addCaptures(
        _ captureIDs: [String],
        to anthologyID: String,
        modifiedAt: String? = nil,
        makeEntryID: @Sendable () -> UUID = UUID.init
    ) throws -> [AnthologyEntryRecord] {
        try db.write { db in
            guard
                let stableSlot = try Int.fetchOne(
                    db,
                    sql: "SELECT next_stable_slot FROM anthology WHERE id = ?",
                    arguments: [anthologyID]
                )
            else {
                throw AnthologyDAOError.anthologyNotFound
            }
            guard captureIDs.isEmpty == false,
                Set(captureIDs).count == captureIDs.count
            else {
                throw AnthologyDAOError.invalidEntryOrder
            }
            let existingCaptureIDs = Set(
                try String.fetchAll(
                    db,
                    sql: "SELECT capture_id FROM anthology_entry WHERE anthology_id = ?",
                    arguments: [anthologyID]))
            guard existingCaptureIDs.isDisjoint(with: captureIDs) else {
                throw AnthologyDAOError.invalidEntryOrder
            }
            for captureID in captureIDs {
                guard try ArticleCaptureRecord.fetchOne(db, key: captureID) != nil else {
                    throw AnthologyDAOError.captureNotFound(captureID)
                }
            }
            let initialSortOrder =
                try Int.fetchOne(
                    db,
                    sql:
                        "SELECT COALESCE(MAX(sort_order), -1) + 1 FROM anthology_entry WHERE anthology_id = ?",
                    arguments: [anthologyID]
                ) ?? 0
            let entries = try captureIDs.enumerated().map { offset, captureID in
                var entry = AnthologyEntryRecord(
                    id: makeEntryID().uuidString,
                    anthologyID: anthologyID,
                    captureID: captureID,
                    sortOrder: initialSortOrder + offset,
                    stableSlot: stableSlot + offset,
                    chapterTitleOverride: nil,
                    narrationVoiceID: nil
                )
                try entry.insert(db)
                return entry
            }
            let nextStableSlot = stableSlot + captureIDs.count
            if let modifiedAt {
                try db.execute(
                    sql: """
                        UPDATE anthology
                        SET next_stable_slot = ?, modified_at = ?
                        WHERE id = ?
                        """,
                    arguments: [nextStableSlot, modifiedAt, anthologyID])
            } else {
                try db.execute(
                    sql: "UPDATE anthology SET next_stable_slot = ? WHERE id = ?",
                    arguments: [nextStableSlot, anthologyID])
            }
            return entries
        }
    }

    func replaceOrder(
        anthologyID: String,
        entryIDs: [String],
        modifiedAt: String? = nil
    ) throws {
        try db.write { db in
            let entries =
                try AnthologyEntryRecord
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
                    sql:
                        "UPDATE anthology_entry SET sort_order = ? WHERE id = ? AND anthology_id = ?",
                    arguments: [sortOrder, entryID, anthologyID]
                )
            }
            if let modifiedAt {
                try db.execute(
                    sql: "UPDATE anthology SET modified_at = ? WHERE id = ?",
                    arguments: [modifiedAt, anthologyID])
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

    func removeEntry(
        id: String,
        anthologyID: String? = nil,
        modifiedAt: String? = nil
    ) throws {
        try db.write { db in
            guard let existing = try AnthologyEntryRecord.fetchOne(db, key: id),
                anthologyID == nil || existing.anthologyID == anthologyID
            else {
                throw AnthologyDAOError.entryNotFound
            }
            _ = try AnthologyEntryRecord.deleteOne(db, key: id)
            let remaining =
                try AnthologyEntryRecord
                .filter(Column("anthology_id") == existing.anthologyID)
                .order(Column("sort_order"), Column("stable_slot"), Column("id"))
                .fetchAll(db)
            for (sortOrder, entry) in remaining.enumerated() where entry.sortOrder != sortOrder {
                try db.execute(
                    sql: "UPDATE anthology_entry SET sort_order = ? WHERE id = ?",
                    arguments: [sortOrder, entry.id])
            }
            if let modifiedAt {
                try db.execute(
                    sql: "UPDATE anthology SET modified_at = ? WHERE id = ?",
                    arguments: [modifiedAt, existing.anthologyID])
            }
        }
    }

    func updateProject(
        id: String,
        title: String,
        subtitle: String?,
        creator: String?,
        coverPath: String?,
        modifiedAt: String
    ) throws {
        try db.write { db in
            try db.execute(
                sql: """
                    UPDATE anthology
                    SET title = ?, subtitle = ?, creator = ?, cover_path = ?, modified_at = ?
                    WHERE id = ?
                    """,
                arguments: [title, subtitle, creator, coverPath, modifiedAt, id])
            guard db.changesCount == 1 else {
                throw AnthologyDAOError.anthologyNotFound
            }
        }
    }

    func updateEntry(
        anthologyID: String,
        entryID: String,
        chapterTitleOverride: String?,
        narrationVoiceID: String?,
        modifiedAt: String
    ) throws {
        try db.write { db in
            try db.execute(
                sql: """
                    UPDATE anthology_entry
                    SET chapter_title_override = ?, narration_voice_id = ?
                    WHERE id = ? AND anthology_id = ?
                    """,
                arguments: [
                    chapterTitleOverride,
                    narrationVoiceID,
                    entryID,
                    anthologyID,
                ])
            guard db.changesCount == 1 else {
                throw AnthologyDAOError.entryNotFound
            }
            try db.execute(
                sql: "UPDATE anthology SET modified_at = ? WHERE id = ?",
                arguments: [modifiedAt, anthologyID])
        }
    }

    func saveDraft(
        anthology: AnthologyRecord,
        entries: [AnthologyEntryRecord],
        expectedEntryIDs: Set<String>,
        modifiedAt: String
    ) throws {
        try db.write { db in
            guard try AnthologyRecord.fetchOne(db, key: anthology.id) != nil else {
                throw AnthologyDAOError.anthologyNotFound
            }
            let stored =
                try AnthologyEntryRecord
                .filter(Column("anthology_id") == anthology.id)
                .fetchAll(db)
            let storedByID = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0) })
            guard Set(storedByID.keys) == expectedEntryIDs else {
                throw AnthologyDAOError.revisionConflict
            }
            guard Set(entries.map(\.id)).count == entries.count,
                entries.map(\.sortOrder) == Array(0..<entries.count)
            else {
                throw AnthologyDAOError.invalidEntryOrder
            }
            for entry in entries {
                guard let original = storedByID[entry.id],
                    entry.anthologyID == anthology.id,
                    entry.captureID == original.captureID,
                    entry.stableSlot == original.stableSlot
                else {
                    throw AnthologyDAOError.invalidEntryOrder
                }
            }

            let retainedIDs = Set(entries.map(\.id))
            for entry in stored where retainedIDs.contains(entry.id) == false {
                _ = try AnthologyEntryRecord.deleteOne(db, key: entry.id)
            }
            for entry in entries {
                try db.execute(
                    sql: """
                        UPDATE anthology_entry
                        SET sort_order = ?,
                            chapter_title_override = ?,
                            narration_voice_id = ?
                        WHERE id = ? AND anthology_id = ?
                        """,
                    arguments: [
                        entry.sortOrder,
                        entry.chapterTitleOverride,
                        entry.narrationVoiceID,
                        entry.id,
                        anthology.id,
                    ])
                guard db.changesCount == 1 else {
                    throw AnthologyDAOError.entryNotFound
                }
            }
            try db.execute(
                sql: """
                    UPDATE anthology
                    SET title = ?, subtitle = ?, creator = ?, cover_path = ?, modified_at = ?
                    WHERE id = ?
                    """,
                arguments: [
                    anthology.title,
                    anthology.subtitle,
                    anthology.creator,
                    anthology.coverPath,
                    modifiedAt,
                    anthology.id,
                ])
            guard db.changesCount == 1 else {
                throw AnthologyDAOError.anthologyNotFound
            }
        }
    }

    func projectSnapshot(id: String) throws -> AnthologyDatabaseSnapshot? {
        try db.read { db in
            guard let anthology = try AnthologyRecord.fetchOne(db, key: id) else {
                return nil
            }
            let entries =
                try AnthologyEntryRecord
                .filter(Column("anthology_id") == id)
                .order(Column("sort_order"), Column("stable_slot"), Column("id"))
                .fetchAll(db)
            let snapshots = try entries.map { entry in
                guard let capture = try ArticleCaptureRecord.fetchOne(db, key: entry.captureID)
                else {
                    throw AnthologyDAOError.captureNotFound(entry.captureID)
                }
                let revision: ArticleRevisionRecord?
                if let revisionID = capture.currentRevisionID {
                    revision = try ArticleRevisionRecord.fetchOne(db, key: revisionID)
                } else {
                    revision = nil
                }
                return AnthologyDatabaseEntrySnapshot(
                    entry: entry,
                    capture: capture,
                    revision: revision)
            }
            let latestBuild = try AnthologyBuildRecord.fetchOne(
                db,
                sql: """
                    SELECT * FROM anthology_build
                    WHERE anthology_id = ? AND status = 'succeeded'
                    ORDER BY revision DESC, created_at DESC, id
                    LIMIT 1
                    """,
                arguments: [id])
            return AnthologyDatabaseSnapshot(
                anthology: anthology,
                entries: snapshots,
                latestSuccessfulBuild: latestBuild)
        }
    }

    func saveBuild(_ build: AnthologyBuildRecord) throws {
        var build = build
        try db.write { db in
            try build.insert(db)
            if build.status == "succeeded" {
                try db.execute(
                    sql: """
                        UPDATE anthology
                        SET latest_build_revision = MAX(latest_build_revision, ?)
                        WHERE id = ?
                        """,
                    arguments: [build.revision, build.anthologyID])
            }
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
