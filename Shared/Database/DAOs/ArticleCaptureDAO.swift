// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

nonisolated enum ArticleCaptureDeletionResult: Equatable, Sendable {
    case deleted
    case notFound
    case referenced(projectNames: [String])
}

nonisolated enum ArticleRevisionPublicationResult: Equatable, Sendable {
    case published(ArticleRevisionRecord)
    case conflict(actualCurrentRevisionID: String?)
}

nonisolated enum ArticleRevisionPublicationError: Swift.Error, Equatable, Sendable {
    case captureNotFound(String)
    case parentMismatch(expected: String?, actual: String?)
    case baseRevisionNotOwned(captureID: String, revisionID: String)
}

nonisolated struct ArticleCaptureDAO: Sendable {
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
                request = request.filter(
                    Column("content_state") != ArticleContentState.captureFailed.rawValue)
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

    func publishRevision(
        _ revision: ArticleRevisionRecord,
        expectedCurrentRevisionID: String?
    ) throws -> ArticleRevisionPublicationResult {
        guard revision.parentRevisionID == expectedCurrentRevisionID else {
            throw ArticleRevisionPublicationError.parentMismatch(
                expected: expectedCurrentRevisionID,
                actual: revision.parentRevisionID)
        }

        do {
            return try db.write { db in
                guard try ArticleCaptureRecord.fetchOne(db, key: revision.captureID) != nil else {
                    throw ArticleRevisionPublicationError.captureNotFound(revision.captureID)
                }
                if let expectedCurrentRevisionID {
                    guard
                        let base = try ArticleRevisionRecord.fetchOne(
                            db,
                            key: expectedCurrentRevisionID),
                        base.captureID == revision.captureID
                    else {
                        throw ArticleRevisionPublicationError.baseRevisionNotOwned(
                            captureID: revision.captureID,
                            revisionID: expectedCurrentRevisionID)
                    }
                }

                var revision = revision
                try revision.insert(db)
                try db.execute(
                    sql: """
                        UPDATE article_capture
                        SET current_revision_id = ?
                        WHERE id = ?
                          AND (
                            (current_revision_id IS NULL AND ? IS NULL)
                            OR current_revision_id = ?
                          )
                        """,
                    arguments: [
                        revision.id,
                        revision.captureID,
                        expectedCurrentRevisionID,
                        expectedCurrentRevisionID,
                    ])
                guard db.changesCount == 1 else {
                    let actual = try String.fetchOne(
                        db,
                        sql: "SELECT current_revision_id FROM article_capture WHERE id = ?",
                        arguments: [revision.captureID])
                    throw ConditionalPublicationConflict(actualCurrentRevisionID: actual)
                }
                return .published(revision)
            }
        } catch let conflict as ConditionalPublicationConflict {
            return .conflict(actualCurrentRevisionID: conflict.actualCurrentRevisionID)
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
            var projectNames = try String.fetchAll(
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
            if let captureID = UUID(uuidString: id) {
                let successfulBuilds = try AnthologyBuildRecord.fetchAll(
                    db,
                    sql: """
                        SELECT * FROM anthology_build
                        WHERE status = 'succeeded'
                        ORDER BY created_at, id
                        """
                )
                for build in successfulBuilds {
                    guard
                        let captureIDs = try AnthologySuccessfulBuildEvidence.captureIDs(in: build),
                        captureIDs.contains(captureID),
                        let title = try String.fetchOne(
                            db,
                            sql: "SELECT title FROM anthology WHERE id = ?",
                            arguments: [build.anthologyID])
                    else {
                        continue
                    }
                    projectNames.append(title)
                }
                projectNames = Array(Set(projectNames)).sorted()
            }
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

private nonisolated struct ConditionalPublicationConflict: Swift.Error {
    let actualCurrentRevisionID: String?
}
