// SPDX-License-Identifier: GPL-3.0-or-later

import CoreLocation
import Foundation
import GRDB

/// Reconstructs listening "sessions" for an audiobook from `playback_event`.
///
/// There is no `playback_session` table. A session is one or more consecutive
/// `event_type='play'` rows whose inter-row wall-clock gap is <= `gapThreshold`.
/// Route comes from `session_location` (FK -> playback_event.id); chapter range
/// from a `chapter` overlap join; counts from `created_at` in the session window.
struct SessionSummaryService {
    let db: DatabaseWriter

    private static let iso = ISO8601DateFormatter()

    /// Returns sessions newest-first.
    func sessions(audiobookID: String, gapThreshold: TimeInterval = 300) throws -> [SessionSummary]
    {
        try db.read { db in
            // 1. Pull closed play segments, oldest-first, to group on gaps.
            let segmentRows = try Row.fetchAll(
                db,
                sql: """
                    SELECT id, started_at, ended_at, start_position, end_position, speed
                    FROM playback_event
                    WHERE audiobook_id = ?
                      AND event_type = 'play'
                      AND ended_at IS NOT NULL
                      AND end_position IS NOT NULL
                    ORDER BY started_at ASC
                    """, arguments: [audiobookID])

            struct Segment {
                let eventID: Int64
                let start: Date
                let end: Date
                let startPos: Double
                let endPos: Double
                let speed: Double
            }

            let segments: [Segment] = segmentRows.compactMap { row in
                guard
                    let startStr: String = row["started_at"],
                    let endStr: String = row["ended_at"],
                    let start = Self.iso.date(from: startStr),
                    let end = Self.iso.date(from: endStr)
                else { return nil }
                return Segment(
                    eventID: row["id"],
                    start: start,
                    end: end,
                    startPos: row["start_position"] ?? 0,
                    endPos: row["end_position"] ?? 0,
                    speed: (row["speed"] as Double?) ?? 1.0
                )
            }

            guard !segments.isEmpty else { return [] }

            // 2. Group consecutive segments on the wall-clock gap.
            var groups: [[Segment]] = []
            var current: [Segment] = [segments[0]]
            for seg in segments.dropFirst() {
                let gap = seg.start.timeIntervalSince(current.last!.end)
                if gap <= gapThreshold {
                    current.append(seg)
                } else {
                    groups.append(current)
                    current = [seg]
                }
            }
            groups.append(current)

            // 3. Build a SessionSummary per group.
            var summaries: [SessionSummary] = []
            for group in groups {
                let startedAt = group.first!.start
                let endedAt = group.map(\.end).max()!
                let startPosition = group.map(\.startPos).min()!
                let endPosition = group.map(\.endPos).max()!
                let minutes =
                    group.reduce(0.0) { acc, s in
                        let dur = max(0, s.endPos - s.startPos)
                        return acc + (s.speed > 0 ? dur / s.speed : dur)
                    } / 60.0

                let startStr = Self.iso.string(from: startedAt)
                let endStr = Self.iso.string(from: endedAt)

                // 3a. Chapter range via overlap join.
                let chapterRow = try Row.fetchOne(
                    db,
                    sql: """
                        SELECT MIN(c.sort_order) AS first_order,
                               MAX(c.sort_order) AS last_order
                        FROM playback_event pe
                        JOIN chapter c ON c.audiobook_id = pe.audiobook_id
                                      AND pe.start_position <= c.end_seconds
                                      AND pe.end_position   >= c.start_seconds
                        WHERE pe.audiobook_id = ?
                          AND pe.event_type = 'play'
                          AND pe.ended_at IS NOT NULL
                          AND pe.started_at >= ?
                          AND pe.started_at <= ?
                        """, arguments: [audiobookID, startStr, endStr])

                let firstOrder = chapterRow?["first_order"] as Int?
                let lastOrder = chapterRow?["last_order"] as Int?
                let firstTitle = try Self.chapterTitle(
                    db, audiobookID: audiobookID, sortOrder: firstOrder)
                let lastTitle = try Self.chapterTitle(
                    db, audiobookID: audiobookID, sortOrder: lastOrder)

                // 3b. Route from session_location for this group's event ids.
                let eventIDs = group.map(\.eventID)
                let placeholders = databaseQuestionMarks(count: eventIDs.count)
                let routeRows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT latitude, longitude, place_name, created_at
                        FROM session_location
                        WHERE playback_event_id IN (\(placeholders))
                        ORDER BY created_at ASC
                        """, arguments: StatementArguments(eventIDs))

                let route: [SessionRoutePoint] = routeRows.compactMap { row in
                    guard
                        let createdStr: String = row["created_at"],
                        let ts = Self.iso.date(from: createdStr)
                    else { return nil }
                    return SessionRoutePoint(
                        latitude: row["latitude"],
                        longitude: row["longitude"],
                        placeName: row["place_name"],
                        timestamp: ts
                    )
                }
                let routeMiles = Self.miles(for: route)

                // 3c. Counts in the wall-clock window.
                let bookmarkCount = try Self.count(
                    db, table: "bookmark", audiobookID: audiobookID, from: startStr, to: endStr
                )
                let cardCount = try Self.count(
                    db, table: "flashcard", audiobookID: audiobookID, from: startStr, to: endStr
                )
                let noteCount = try Self.count(
                    db, table: "note", audiobookID: audiobookID, from: startStr, to: endStr
                )

                summaries.append(
                    SessionSummary(
                        id: "\(audiobookID)#\(startStr)",
                        audiobookID: audiobookID,
                        startedAt: startedAt,
                        endedAt: endedAt,
                        startPosition: startPosition,
                        endPosition: endPosition,
                        minutesListened: minutes,
                        firstChapterTitle: firstTitle,
                        lastChapterTitle: lastTitle,
                        firstChapterSortOrder: firstOrder,
                        lastChapterSortOrder: lastOrder,
                        bookmarkCount: bookmarkCount,
                        cardCount: cardCount,
                        noteCount: noteCount,
                        imageCount: 0,
                        route: route,
                        routeMiles: routeMiles
                    ))
            }

            return summaries.reversed()  // newest-first
        }
    }

    // MARK: - Helpers

    private static func chapterTitle(
        _ db: Database, audiobookID: String, sortOrder: Int?
    ) throws -> String? {
        guard let sortOrder else { return nil }
        return try String.fetchOne(
            db,
            sql: """
                SELECT title FROM chapter
                WHERE audiobook_id = ? AND sort_order = ?
                LIMIT 1
                """, arguments: [audiobookID, sortOrder])
    }

    private static func count(
        _ db: Database, table: String, audiobookID: String, from: String, to: String
    ) throws -> Int {
        // Tolerate a missing table gracefully.
        let exists =
            try Bool.fetchOne(
                db,
                sql: """
                    SELECT 1 FROM sqlite_master WHERE type='table' AND name=? LIMIT 1
                    """, arguments: [table]) ?? false
        guard exists else { return 0 }
        return try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*) FROM \(table)
                WHERE audiobook_id = ?
                  AND created_at >= ?
                  AND created_at <= ?
                """, arguments: [audiobookID, from, to]) ?? 0
    }

    private static func miles(for route: [SessionRoutePoint]) -> Double {
        guard route.count >= 2 else { return 0 }
        var meters = 0.0
        for i in 1..<route.count {
            let a = CLLocation(latitude: route[i - 1].latitude, longitude: route[i - 1].longitude)
            let b = CLLocation(latitude: route[i].latitude, longitude: route[i].longitude)
            meters += b.distance(from: a)
        }
        return meters / 1609.344
    }
}
