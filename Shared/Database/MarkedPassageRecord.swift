import Foundation
import GRDB

/// GRDB record for the `marked_passage` table (Schema_V15).
/// Represents a timestamp range the user flagged for later flashcard conversion.
struct MarkedPassageRecord: Codable, FetchableRecord, MutablePersistableRecord {
    var id: String
    var audiobookID: String
    var mediaTimestamp: TimeInterval
    var endTimestamp: TimeInterval?
    var transcriptSnippet: String?
    var status: String  // "inbox", "converted", "dismissed"
    var convertedCardID: String?
    var note: String?
    var createdAt: String

    static let databaseTableName = "marked_passage"

    enum CodingKeys: String, CodingKey {
        case id
        case audiobookID = "audiobook_id"
        case mediaTimestamp = "media_timestamp"
        case endTimestamp = "end_timestamp"
        case transcriptSnippet = "transcript_snippet"
        case status
        case convertedCardID = "converted_card_id"
        case note
        case createdAt = "created_at"
    }
}

/// Application-level model for the mark-later inbox.
struct MarkedPassage: Identifiable, Equatable, Sendable {
    var id: String
    var audiobookID: String
    var bookTitle: String
    var mediaTimestamp: TimeInterval
    var endTimestamp: TimeInterval?
    var transcriptSnippet: String?
    var status: MarkedPassageStatus
    var convertedCardID: String?
    var note: String?
    var createdAt: Date

    enum MarkedPassageStatus: String, Sendable {
        case inbox
        case converted
        case dismissed
    }
}

// MARK: - DAO

struct MarkedPassageDAO {
    let db: DatabaseWriter

    func insert(
        audiobookID: String,
        mediaTimestamp: TimeInterval,
        endTimestamp: TimeInterval?,
        transcriptSnippet: String?,
        note: String?
    ) throws -> MarkedPassageRecord {
        let record = MarkedPassageRecord(
            id: UUID().uuidString,
            audiobookID: audiobookID,
            mediaTimestamp: mediaTimestamp,
            endTimestamp: endTimestamp,
            transcriptSnippet: transcriptSnippet,
            status: "inbox",
            convertedCardID: nil,
            note: note,
            createdAt: Date().ISO8601Format()
        )
        try db.write { db in var rec = record; try rec.insert(db) }
        return record
    }

    func fetchInbox(for audiobookID: String) throws -> [MarkedPassageRecord] {
        try db.read { db in
            try MarkedPassageRecord
                .filter(Column("audiobook_id") == audiobookID)
                .filter(Column("status") == "inbox")
                .order(Column("created_at").desc)
                .fetchAll(db)
        }
    }

    func fetchAllInbox() throws -> [MarkedPassageRecord] {
        try db.read { db in
            try MarkedPassageRecord
                .filter(Column("status") == "inbox")
                .order(Column("created_at").desc)
                .fetchAll(db)
        }
    }

    func markConverted(id: String, cardID: String) throws {
        try db.write { db in
            try db.execute(sql: """
                UPDATE marked_passage SET status = 'converted', converted_card_id = ? WHERE id = ?
                """, arguments: [cardID, id])
        }
    }

    func dismiss(id: String) throws {
        try db.write { db in
            try db.execute(sql: """
                UPDATE marked_passage SET status = 'dismissed' WHERE id = ?
                """, arguments: [id])
        }
    }

    func inboxCount() throws -> Int {
        try db.read { db in
            try MarkedPassageRecord
                .filter(Column("status") == "inbox")
                .fetchCount(db)
        }
    }
}
