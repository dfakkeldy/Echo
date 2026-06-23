// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import GRDB
import Testing

@testable import Echo

@Suite struct SessionSummaryServiceTests {
    private static let iso = ISO8601DateFormatter()

    /// Inserts a closed play segment and returns its event id.
    @discardableResult
    private func insertSegment(
        _ db: Database,
        audiobookID: String,
        start: Date,
        durationSec: TimeInterval,
        startPos: Double,
        endPos: Double,
        speed: Double = 1.0
    ) throws -> Int64 {
        try db.execute(
            sql: """
                INSERT INTO playback_event
                  (audiobook_id, started_at, ended_at, start_position, end_position, speed, event_type)
                VALUES (?, ?, ?, ?, ?, ?, 'play')
                """,
            arguments: [
                audiobookID,
                Self.iso.string(from: start),
                Self.iso.string(from: start.addingTimeInterval(durationSec)),
                startPos, endPos, speed,
            ])
        return db.lastInsertedRowID
    }

    private func insertAudiobook(_ db: Database, id: String) throws {
        // Minimal audiobook row to satisfy FK and NOT NULL constraints.
        // Schema_V1 requires title NOT NULL and duration NOT NULL (no default).
        try db.execute(
            sql: "INSERT INTO audiobook (id, title, duration) VALUES (?, ?, 0.0)",
            arguments: [id, "Bk"]
        )
    }

    @Test func twoSegmentsWithinGapFormOneSession() throws {
        let dbService = try DatabaseService(inMemory: ())
        let svc = SessionSummaryService(db: dbService.writer)
        let bk = "bk1"
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        try dbService.writer.write { db in
            try insertAudiobook(db, id: bk)
            // segment A: 0..60s audio, 60s wall
            try insertSegment(
                db, audiobookID: bk, start: base, durationSec: 60, startPos: 0, endPos: 60)
            // segment B starts 30s after A ends (gap < 300) -> same session
            try insertSegment(
                db, audiobookID: bk, start: base.addingTimeInterval(90), durationSec: 60,
                startPos: 60, endPos: 120)
        }

        let sessions = try svc.sessions(audiobookID: bk)
        #expect(sessions.count == 1)
        #expect(sessions[0].startPosition == 0)
        #expect(sessions[0].endPosition == 120)
        // 120s audio / speed 1 / 60 = 2.0 minutes
        #expect(abs(sessions[0].minutesListened - 2.0) < 0.001)
    }

    @Test func gapAboveThresholdSplitsSessions() throws {
        let dbService = try DatabaseService(inMemory: ())
        let svc = SessionSummaryService(db: dbService.writer)
        let bk = "bk2"
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        try dbService.writer.write { db in
            try insertAudiobook(db, id: bk)
            try insertSegment(
                db, audiobookID: bk, start: base, durationSec: 60, startPos: 0, endPos: 60)
            // 10 minutes later -> new session
            try insertSegment(
                db, audiobookID: bk, start: base.addingTimeInterval(660), durationSec: 60,
                startPos: 60, endPos: 120)
        }

        let sessions = try svc.sessions(audiobookID: bk)
        #expect(sessions.count == 2)
        // newest-first
        #expect(sessions[0].startPosition == 60)
        #expect(sessions[1].startPosition == 0)
    }

    @Test func speedAdjustsMinutes() throws {
        let dbService = try DatabaseService(inMemory: ())
        let svc = SessionSummaryService(db: dbService.writer)
        let bk = "bk3"
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        try dbService.writer.write { db in
            try insertAudiobook(db, id: bk)
            // 120s of audio at 2x = 1.0 adjusted minute
            try insertSegment(
                db, audiobookID: bk, start: base, durationSec: 60, startPos: 0, endPos: 120,
                speed: 2.0)
        }

        let sessions = try svc.sessions(audiobookID: bk)
        #expect(sessions.count == 1)
        #expect(abs(sessions[0].minutesListened - 1.0) < 0.001)
    }

    @Test func routeMilesComputedFromLocations() throws {
        // session_location has playback_event_id as PRIMARY KEY (one row per event).
        // To get 2 route points in one session, use 2 play segments within the gap
        // threshold, each with its own session_location row.
        let dbService = try DatabaseService(inMemory: ())
        let svc = SessionSummaryService(db: dbService.writer)
        let bk = "bk4"
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        try dbService.writer.write { db in
            try insertAudiobook(db, id: bk)
            // Two segments 30s apart (gap < 300s) → one session.
            let eid1 = try insertSegment(
                db, audiobookID: bk, start: base, durationSec: 60, startPos: 0, endPos: 60)
            let eid2 = try insertSegment(
                db, audiobookID: bk, start: base.addingTimeInterval(90), durationSec: 60,
                startPos: 60, endPos: 120)
            // One session_location per playback_event (FK = PK constraint).
            try db.execute(
                sql: """
                    INSERT INTO session_location (playback_event_id, latitude, longitude, place_name, created_at)
                    VALUES (?, ?, ?, ?, ?)
                    """, arguments: [eid1, 40.0, -74.0, "A", Self.iso.string(from: base)])
            try db.execute(
                sql: """
                    INSERT INTO session_location (playback_event_id, latitude, longitude, place_name, created_at)
                    VALUES (?, ?, ?, ?, ?)
                    """,
                arguments: [
                    eid2, 40.01, -74.0, "B",
                    Self.iso.string(from: base.addingTimeInterval(90)),
                ])
        }

        let sessions = try svc.sessions(audiobookID: bk)
        #expect(sessions.count == 1)
        #expect(sessions[0].route.count == 2)
        #expect(sessions[0].hasRoute)
        #expect(sessions[0].routeMiles > 0)
        #expect(sessions[0].route[0].placeName == "A")
    }

    @Test func emptyWhenNoSegments() throws {
        let dbService = try DatabaseService(inMemory: ())
        let svc = SessionSummaryService(db: dbService.writer)
        try dbService.writer.write { db in try insertAudiobook(db, id: "empty") }
        #expect(try svc.sessions(audiobookID: "empty").isEmpty)
    }
}
