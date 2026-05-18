import Foundation
import GRDB

struct TranscriptionDAO {
    let db: DatabaseWriter

    func segments(for audiobookID: String) throws -> [TranscriptionRecord] {
        try db.read { db in
            try TranscriptionRecord
                .filter(Column("audiobook_id") == audiobookID)
                .order(Column("start_time"))
                .fetchAll(db)
        }
    }

    func insertAll(_ segments: [TranscriptionRecord], audiobookID: String) throws {
        try db.write { db in
            for var segment in segments {
                try segment.insert(db)
            }
        }
    }

    /// FTS5 full-text search across transcription segments.
    func search(_ query: String, audiobookID: String) throws -> [TranscriptionRecord] {
        try db.read { db in
            let pattern = query.split(separator: " ").map { "\($0)*" }.joined(separator: " ")
            let sql = """
                SELECT ts.* FROM transcription_segment ts
                JOIN transcription_fts fts ON ts.id = fts.rowid
                WHERE transcription_fts MATCH :query
                AND ts.audiobook_id = :audiobookID
                ORDER BY rank
                """
            return try TranscriptionRecord.fetchAll(
                db, sql: sql,
                arguments: ["query": pattern, "audiobookID": audiobookID]
            )
        }
    }

    func insertWords(_ words: [TranscriptionWord], segmentID: Int64) throws {
        try db.write { db in
            for word in words {
                try db.execute(
                    sql: """
                        INSERT INTO transcription_word (segment_id, word, start_time, end_time, position)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                    arguments: [segmentID, word.word, word.startTime, word.endTime, word.position]
                )
            }
        }
    }

    func deleteAll(for audiobookID: String) throws {
        try db.write { db in
            try TranscriptionRecord
                .filter(Column("audiobook_id") == audiobookID)
                .deleteAll(db)
        }
    }
}
