// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

/// DAO for alignment anchors — user-created or auto-generated lock points
/// that tie an EPUB block to a specific audio timestamp.
struct AlignmentAnchorDAO {
    let db: DatabaseWriter

    // MARK: - Insert

    func insert(_ anchor: AlignmentAnchorRecord) throws {
        var mutable = anchor
        try db.write { db in
            try mutable.insert(db)
        }
    }

    // MARK: - Delete

    func deleteAll(for audiobookID: String) throws {
        _ = try db.write { db in
            try AlignmentAnchorRecord
                .filter(Column("audiobook_id") == audiobookID)
                .deleteAll(db)
        }
    }

    func delete(id: String) throws {
        _ = try db.write { db in
            try AlignmentAnchorRecord
                .filter(Column("id") == id)
                .deleteAll(db)
        }
    }

    /// Deletes every machine-made anchor (Tier 0 title matches, DTW content
    /// anchors, and continuous-background anchors) so a re-run starts from a
    /// clean slate and can correct earlier mistakes. Human-made anchors are
    /// preserved.
    /// - Returns: The number of anchors removed.
    @discardableResult
    func deleteAutoPipelineAnchors(for audiobookID: String) throws -> Int {
        try db.write { db in
            try AlignmentAnchorRecord
                .filter(Column("audiobook_id") == audiobookID)
                .filter(
                    Column("id").like("auto-tier0-%")
                        || Column("id").like("auto-dtw-%")
                        || Column("id").like("auto-continuous-%")
                )
                .deleteAll(db)
        }
    }

    /// Deletes every anchor for `audiobookID` whose `source` column equals
    /// `source`. Used by source-backed transcript alignment to clear only its
    /// own `.transcriptAlignment` anchors on re-run, leaving hand-placed and
    /// other-pipeline anchors intact (the queryable counterpart to the legacy
    /// id-prefix `deleteAutoPipelineAnchors`).
    /// - Returns: The number of anchors removed.
    @discardableResult
    func deleteAnchors(for audiobookID: String, source: String) throws -> Int {
        try db.write { db in
            try AlignmentAnchorRecord
                .filter(Column("audiobook_id") == audiobookID)
                .filter(Column("source") == source)
                .deleteAll(db)
        }
    }

    // MARK: - Queries

    /// All anchors for an audiobook, ordered by audio time.
    func anchors(for audiobookID: String) throws -> [AlignmentAnchorRecord] {
        try db.read { db in
            try AlignmentAnchorRecord
                .filter(Column("audiobook_id") == audiobookID)
                .order(Column("audio_time"))
                .fetchAll(db)
        }
    }

    /// Anchor for a specific EPUB block, if any.
    func anchor(for audiobookID: String, epubBlockID: String) throws -> AlignmentAnchorRecord? {
        try db.read { db in
            try AlignmentAnchorRecord
                .filter(Column("audiobook_id") == audiobookID)
                .filter(Column("epub_block_id") == epubBlockID)
                .fetchOne(db)
        }
    }

    /// Whether any anchor exists for `audiobookID` on any of `epubBlockIDs`.
    /// Used to answer "does this chapter have audio?" over a whole block range,
    /// since anchors usually land on content blocks rather than the heading block.
    func hasAnchor(for audiobookID: String, anyOf epubBlockIDs: [String]) throws -> Bool {
        guard !epubBlockIDs.isEmpty else { return false }
        return try db.read { db in
            try AlignmentAnchorRecord
                .filter(Column("audiobook_id") == audiobookID)
                .filter(epubBlockIDs.contains(Column("epub_block_id")))
                .limit(1)
                .fetchOne(db) != nil
        }
    }

    /// Anchors within a time window, ordered by audio time.
    func anchors(
        for audiobookID: String,
        in timeRange: ClosedRange<TimeInterval>
    ) throws -> [AlignmentAnchorRecord] {
        try db.read { db in
            try AlignmentAnchorRecord
                .filter(Column("audiobook_id") == audiobookID)
                .filter(Column("audio_time") >= timeRange.lowerBound)
                .filter(Column("audio_time") <= timeRange.upperBound)
                .order(Column("audio_time"))
                .fetchAll(db)
        }
    }

    /// The two anchors that bracket a given time, for interpolation.
    /// Returns (previousAnchor, nextAnchor) — either may be nil at edges.
    func bracketingAnchors(
        for audiobookID: String,
        around time: TimeInterval
    ) throws -> (AlignmentAnchorRecord?, AlignmentAnchorRecord?) {
        try db.read { db in
            let before =
                try AlignmentAnchorRecord
                .filter(Column("audiobook_id") == audiobookID)
                .filter(Column("audio_time") <= time)
                .order(Column("audio_time").desc)
                .limit(1)
                .fetchOne(db)

            let after =
                try AlignmentAnchorRecord
                .filter(Column("audiobook_id") == audiobookID)
                .filter(Column("audio_time") > time)
                .order(Column("audio_time"))
                .limit(1)
                .fetchOne(db)

            return (before, after)
        }
    }

    // MARK: - Point lookup

    /// The `epub_block_id` of the alignment anchor at or immediately before
    /// `time` for the given audiobook. Returns `nil` when no anchor exists.
    func block(at time: TimeInterval, audiobookID: String) -> String? {
        (try? db.read { db in
            try String.fetchOne(
                db,
                sql: """
                    SELECT epub_block_id FROM alignment_anchor
                    WHERE audiobook_id = ? AND audio_time <= ?
                    ORDER BY audio_time DESC LIMIT 1
                    """,
                arguments: [audiobookID, time])
        }) ?? nil
    }

    // MARK: - Upsert

    func upsert(_ anchor: AlignmentAnchorRecord) throws {
        var mutable = anchor
        try db.write { db in
            try mutable.upsert(db)
        }
    }
}
