import Testing
import Foundation
import GRDB
@testable import Echo

@MainActor
struct PlaybackSessionRecorderTests {
    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    private func makeDB() throws -> DatabaseService {
        try DatabaseService(inMemory: ())
    }

    private func rows(_ db: DatabaseService) throws -> [Row] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM playback_event ORDER BY id")
        }
    }

    @Test func playPauseProducesOneSegmentAndStubsAudiobook() async throws {
        let db = try makeDB()
        let recorder = PlaybackSessionRecorder(writer: db.writer)
        recorder.yield(.opened(audiobookID: "file:///b1/", trackID: nil, position: 100, speed: 1.5, source: "user", at: t0))
        recorder.yield(.progressTick(position: 150, at: t0.addingTimeInterval(50)))
        recorder.yield(.closed(position: 160, at: t0.addingTimeInterval(60)))
        await recorder.drain()

        let segs = try rows(db)
        #expect(segs.count == 1)
        #expect(segs[0]["start_position"] == 100.0)
        #expect(segs[0]["end_position"] == 160.0)
        #expect(segs[0]["speed"] == 1.5)
        // FK satisfied via auto-stub:
        let book = try db.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM audiobook WHERE id = 'file:///b1/'")
        }
        #expect(book != nil)
    }

    @Test func seekProducesTwoSegments() async throws {
        let db = try makeDB()
        let recorder = PlaybackSessionRecorder(writer: db.writer)
        recorder.yield(.opened(audiobookID: "b", trackID: nil, position: 0, speed: 1.0, source: "user", at: t0))
        recorder.yield(.progressTick(position: 30, at: t0.addingTimeInterval(30)))
        recorder.yield(.seeked(toPosition: 300, at: t0.addingTimeInterval(31)))
        recorder.yield(.closed(position: 330, at: t0.addingTimeInterval(61)))
        await recorder.drain()

        let segs = try rows(db)
        #expect(segs.count == 2)
        #expect(segs[0]["end_position"] == 30.0)
        #expect(segs[1]["start_position"] == 300.0)
        #expect(segs[1]["end_position"] == 330.0)
    }

    @Test func microSegmentIsDeletedFromDB() async throws {
        let db = try makeDB()
        let recorder = PlaybackSessionRecorder(writer: db.writer)
        recorder.yield(.opened(audiobookID: "b", trackID: nil, position: 0, speed: 1.0, source: "user", at: t0))
        recorder.yield(.closed(position: 2, at: t0.addingTimeInterval(2)))
        await recorder.drain()
        #expect(try rows(db).isEmpty)
    }

    @Test func unknownTrackRetriesWithNilTrackID() async throws {
        let db = try makeDB()
        let recorder = PlaybackSessionRecorder(writer: db.writer)
        // 'trk-missing' has no track row → first insert violates FK → retried with nil.
        recorder.yield(.opened(audiobookID: "b", trackID: "trk-missing", position: 0, speed: 1.0, source: "user", at: t0))
        recorder.yield(.closed(position: 60, at: t0.addingTimeInterval(60)))
        await recorder.drain()
        let segs = try rows(db)
        #expect(segs.count == 1)
        #expect(segs[0]["track_id"] == nil)
    }

    @Test func heartbeatPersistsProgressForCrashSafety() async throws {
        let db = try makeDB()
        let recorder = PlaybackSessionRecorder(writer: db.writer)
        recorder.yield(.opened(audiobookID: "b", trackID: nil, position: 0, speed: 1.0, source: "user", at: t0))
        recorder.yield(.progressTick(position: 29, at: t0.addingTimeInterval(29)))
        recorder.yield(.heartbeat(at: t0.addingTimeInterval(30)))
        await recorder.drain()
        // No close — simulate crash by just reading current state.
        let segs = try rows(db)
        #expect(segs.count == 1)
        #expect(segs[0]["end_position"] == 29.0)
        #expect(segs[0]["ended_at"] == t0.addingTimeInterval(30).ISO8601Format())
    }
}
