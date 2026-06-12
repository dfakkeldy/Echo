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

    /// Anchors within a time window, ordered by audio time.
    func anchors(for audiobookID: String,
                in timeRange: ClosedRange<TimeInterval>) throws -> [AlignmentAnchorRecord] {
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
    func bracketingAnchors(for audiobookID: String,
                           around time: TimeInterval) throws -> (AlignmentAnchorRecord?, AlignmentAnchorRecord?) {
        try db.read { db in
            let before = try AlignmentAnchorRecord
                .filter(Column("audiobook_id") == audiobookID)
                .filter(Column("audio_time") <= time)
                .order(Column("audio_time").desc)
                .limit(1)
                .fetchOne(db)

            let after = try AlignmentAnchorRecord
                .filter(Column("audiobook_id") == audiobookID)
                .filter(Column("audio_time") > time)
                .order(Column("audio_time"))
                .limit(1)
                .fetchOne(db)

            return (before, after)
        }
    }

    // MARK: - Upsert

    func upsert(_ anchor: AlignmentAnchorRecord) throws {
        var mutable = anchor
        try db.write { db in
            try mutable.upsert(db)
        }
    }
}
