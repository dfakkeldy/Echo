// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

/// A resolved scope: a wall-clock window plus the book-position range it covered.
/// `coveredStartPosition`/`coveredEndPosition` are book seconds derived from
/// `playback_event` rows inside the window. `listenedSeconds` is wall-clock listening
/// time (segment span ÷ speed) summed across those rows.
public struct FeedScopeWindow: Equatable, Sendable {
    public let startedAt: Date
    public let endedAt: Date
    public let coveredStartPosition: TimeInterval
    public let coveredEndPosition: TimeInterval
    public let listenedSeconds: TimeInterval

    public init(
        startedAt: Date,
        endedAt: Date,
        coveredStartPosition: TimeInterval,
        coveredEndPosition: TimeInterval,
        listenedSeconds: TimeInterval
    ) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.coveredStartPosition = coveredStartPosition
        self.coveredEndPosition = coveredEndPosition
        self.listenedSeconds = listenedSeconds
    }
}

/// Resolves a `FeedScope` to a concrete `FeedScopeWindow`.
///
/// "Session" is two systems (no `playback_session` table): the coarse
/// `real_time_event` (`event_type='playback_session'`) gives the wall-clock window;
/// `playback_event` (`event_type='play'`) gives the covered book-position range and
/// listened minutes. We do NOT join the two tables on `audiobook_id` — `real_time_event`
/// stores a folder URL there while `playback_event` stores the GRDB UUID — instead we
/// find the latest session marker by recency, then intersect `playback_event` (queried
/// by the GRDB `audiobook.id`) on `started_at` within that window.
public struct FeedScopeResolver {
    public let db: DatabaseWriter

    public init(db: DatabaseWriter) {
        self.db = db
    }

    private static let iso = ISO8601DateFormatter()

    /// The most recent `playback_session` marker's window, with the covered range
    /// derived from `playback_event` rows inside it. Returns nil if no marker exists.
    public func lastSessionWindow(audiobookID: String) throws -> FeedScopeWindow? {
        try db.read { db in
            guard
                let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT started_at, ended_at
                        FROM real_time_event
                        WHERE event_type = 'playback_session'
                        ORDER BY started_at DESC
                        LIMIT 1
                        """)
            else { return nil }
            return try Self.window(db: db, audiobookID: audiobookID, markerRow: row)
        }
    }

    /// A specific session marker's window (for a future session picker). Returns nil
    /// if no marker with that id exists.
    public func sessionWindow(id: String, audiobookID: String) throws -> FeedScopeWindow? {
        try db.read { db in
            guard
                let row = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT started_at, ended_at
                        FROM real_time_event
                        WHERE event_type = 'playback_session' AND id = ?
                        LIMIT 1
                        """, arguments: [id])
            else { return nil }
            return try Self.window(db: db, audiobookID: audiobookID, markerRow: row)
        }
    }

    /// Builds a window from a marker row + the in-window `playback_event` aggregation.
    private static func window(
        db: Database,
        audiobookID: String,
        markerRow: Row
    ) throws -> FeedScopeWindow? {
        guard let startedAtStr: String = markerRow["started_at"],
            let startedAt = iso.date(from: startedAtStr)
        else { return nil }
        // Open session → upper bound is now.
        let endedAt: Date
        if let endedAtStr: String = markerRow["ended_at"], let d = iso.date(from: endedAtStr) {
            endedAt = d
        } else {
            endedAt = Date()
        }

        let startStr = iso.string(from: startedAt)
        let endStr = iso.string(from: endedAt)

        // Covered position range + listened seconds over in-window play segments.
        // Closed range on started_at (sessions are inclusive at both ends).
        let agg = try Row.fetchOne(
            db,
            sql: """
                SELECT MIN(start_position) AS min_pos,
                       MAX(end_position)   AS max_pos,
                       SUM((end_position - start_position) / speed) AS listened
                FROM playback_event
                WHERE audiobook_id = ?
                  AND event_type = 'play'
                  AND ended_at IS NOT NULL
                  AND started_at >= ?
                  AND started_at <= ?
                """, arguments: [audiobookID, startStr, endStr])

        let minPos: Double = agg?["min_pos"] ?? 0
        let maxPos: Double = agg?["max_pos"] ?? 0
        let listened: Double = agg?["listened"] ?? 0

        return FeedScopeWindow(
            startedAt: startedAt,
            endedAt: endedAt,
            coveredStartPosition: minPos,
            coveredEndPosition: maxPos,
            listenedSeconds: max(0, listened)
        )
    }
}
