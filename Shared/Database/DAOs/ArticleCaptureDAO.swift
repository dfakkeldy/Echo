// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

nonisolated enum ArticleCaptureDeletionResult: Equatable, Sendable {
    case deleted
    case notFound
    case referenced(projectNames: [String])
}

nonisolated struct ArticleCaptureDAO {
    private let db: DatabaseWriter

    init(db: DatabaseWriter) {
        self.db = db
    }

    func saveCapture(_ record: ArticleCaptureRecord) throws {
        var record = record
        try db.write { db in
            try record.save(db)
        }
    }

    func capture(id: String) throws -> ArticleCaptureRecord? {
        try db.read { db in
            try ArticleCaptureRecord.fetchOne(db, key: id)
        }
    }

    func captures(includeFailures: Bool = true) throws -> [ArticleCaptureRecord] {
        try db.read { db in
            var request = ArticleCaptureRecord.order(Column("captured_at").desc, Column("id"))
            if !includeFailures {
                request = request.filter(Column("content_state") != "failed")
            }
            return try request.fetchAll(db)
        }
    }

    func possibleDuplicates(canonicalURL: String?, digest: String) throws -> [ArticleCaptureRecord]
    {
        try db.read { db in
            let sql: String
            let arguments: StatementArguments
            if let canonicalURL {
                sql = """
                    SELECT * FROM article_capture
                    WHERE canonical_url = ? OR content_sha256 = ?
                    ORDER BY captured_at DESC, id
                    """
                arguments = [canonicalURL, digest]
            } else {
                sql = """
                    SELECT * FROM article_capture
                    WHERE content_sha256 = ?
                    ORDER BY captured_at DESC, id
                    """
                arguments = [digest]
            }
            return try ArticleCaptureRecord.fetchAll(db, sql: sql, arguments: arguments)
        }
    }

    func saveRevision(_ revision: ArticleRevisionRecord, makeCurrent: Bool) throws {
        var revision = revision
        try db.write { db in
            try revision.save(db)
            if makeCurrent {
                try db.execute(
                    sql: "UPDATE article_capture SET current_revision_id = ? WHERE id = ?",
                    arguments: [revision.id, revision.captureID]
                )
            }
        }
    }

    func revisions(captureID: String) throws -> [ArticleRevisionRecord] {
        try db.read { db in
            try ArticleRevisionRecord
                .filter(Column("capture_id") == captureID)
                .order(Column("created_at"), Column("id"))
                .fetchAll(db)
        }
    }

    func currentRevision(captureID: String) throws -> ArticleRevisionRecord? {
        try db.read { db in
            try ArticleRevisionRecord.fetchOne(
                db,
                sql: """
                    SELECT article_revision.*
                    FROM article_capture
                    JOIN article_revision ON article_revision.id = article_capture.current_revision_id
                    WHERE article_capture.id = ?
                    """,
                arguments: [captureID]
            )
        }
    }

    func deleteCapture(id: String) throws {
        _ = try db.write { db in
            try ArticleCaptureRecord.deleteOne(db, key: id)
        }
    }

    func deleteCaptureIfUnreferenced(id: String) throws -> ArticleCaptureDeletionResult {
        try db.write { db in
            let projectNames = try String.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT anthology.title
                    FROM anthology_entry
                    JOIN anthology ON anthology.id = anthology_entry.anthology_id
                    WHERE anthology_entry.capture_id = ?
                    ORDER BY anthology.title
                    """,
                arguments: [id]
            )
            guard projectNames.isEmpty else {
                return .referenced(projectNames: projectNames)
            }
            guard try ArticleCaptureRecord.fetchOne(db, key: id) != nil else {
                return .notFound
            }
            _ = try ArticleCaptureRecord.deleteOne(db, key: id)
            return .deleted
        }
    }
}
