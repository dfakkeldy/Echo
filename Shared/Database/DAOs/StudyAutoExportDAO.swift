// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

/// The single user-picked auto-export destination.
struct StudyExportDestinationRecord: Codable, Equatable, FetchableRecord, MutablePersistableRecord {
    var id: String
    var bookmark: Data
    var displayPath: String
    var needsRepick: Bool
    var addedAt: String

    static let databaseTableName = "study_export_destination"
    static let defaultID = "default"

    enum CodingKeys: String, CodingKey {
        case id
        case bookmark
        case displayPath = "display_path"
        case needsRepick = "needs_repick"
        case addedAt = "added_at"
    }
}

/// Per-book export state. Dirty rows are the persisted retry outbox.
struct StudyExportStateRecord: Codable, Equatable, FetchableRecord, MutablePersistableRecord {
    var bookId: String
    var fileName: String?
    var dirty: Bool
    var contentSha256: String?
    var lastExportedAt: String?
    var lastError: String?

    static let databaseTableName = "study_export_state"

    enum CodingKeys: String, CodingKey {
        case bookId = "book_id"
        case fileName = "file_name"
        case dirty
        case contentSha256 = "content_sha256"
        case lastExportedAt = "last_exported_at"
        case lastError = "last_error"
    }
}

struct StudyAutoExportDAO {
    private let db: DatabaseWriter

    init(db: DatabaseWriter) {
        self.db = db
    }

    func destination() throws -> StudyExportDestinationRecord? {
        try db.read { db in
            try StudyExportDestinationRecord.fetchOne(
                db,
                key: StudyExportDestinationRecord.defaultID
            )
        }
    }

    func saveDestination(bookmark: Data, displayPath: String) throws {
        var record = StudyExportDestinationRecord(
            id: StudyExportDestinationRecord.defaultID,
            bookmark: bookmark,
            displayPath: displayPath,
            needsRepick: false,
            addedAt: Date.now.ISO8601Format()
        )

        try db.write { db in
            try record.save(db)
        }
    }

    func clearDestination() throws {
        _ = try db.write { db in
            try StudyExportDestinationRecord.deleteOne(
                db,
                key: StudyExportDestinationRecord.defaultID
            )
        }
    }

    func setNeedsRepick(_ needsRepick: Bool) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE study_export_destination SET needs_repick = ? WHERE id = ?",
                arguments: [needsRepick, StudyExportDestinationRecord.defaultID]
            )
        }
    }

    func markDirty(bookIDs: [String]) throws {
        guard !bookIDs.isEmpty else { return }

        try db.write { db in
            for bookID in bookIDs {
                if var existing = try StudyExportStateRecord.fetchOne(db, key: bookID) {
                    existing.dirty = true
                    try existing.save(db)
                } else {
                    var fresh = StudyExportStateRecord(
                        bookId: bookID,
                        fileName: nil,
                        dirty: true,
                        contentSha256: nil,
                        lastExportedAt: nil,
                        lastError: nil
                    )
                    try fresh.save(db)
                }
            }
        }
    }

    func dirtyStates() throws -> [StudyExportStateRecord] {
        try db.read { db in
            try StudyExportStateRecord
                .filter(Column("dirty") == true)
                .order(Column("book_id"))
                .fetchAll(db)
        }
    }

    func state(for bookID: String) throws -> StudyExportStateRecord? {
        try db.read { db in
            try StudyExportStateRecord.fetchOne(db, key: bookID)
        }
    }

    func recordSuccess(
        bookID: String,
        fileName: String,
        contentSha256: String,
        at date: String
    ) throws {
        var record = StudyExportStateRecord(
            bookId: bookID,
            fileName: fileName,
            dirty: false,
            contentSha256: contentSha256,
            lastExportedAt: date,
            lastError: nil
        )

        try db.write { db in
            try record.save(db)
        }
    }

    func recordFailure(bookID: String, error: String) throws {
        try db.write { db in
            if var existing = try StudyExportStateRecord.fetchOne(db, key: bookID) {
                existing.dirty = true
                existing.lastError = error
                try existing.save(db)
            } else {
                var record = StudyExportStateRecord(
                    bookId: bookID,
                    fileName: nil,
                    dirty: true,
                    contentSha256: nil,
                    lastExportedAt: nil,
                    lastError: error
                )
                try record.save(db)
            }
        }
    }

    func removeState(bookID: String) throws {
        _ = try db.write { db in
            try StudyExportStateRecord.deleteOne(db, key: bookID)
        }
    }
}
