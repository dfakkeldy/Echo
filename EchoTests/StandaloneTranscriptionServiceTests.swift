// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
struct StandaloneTranscriptionServiceTests {

    /// Creates an in-memory database with the current baseline schema applied.
    private func makeTestDB() throws -> DatabaseWriter {
        try DatabaseService(inMemory: ()).writer
    }

    // MARK: - Record Persistence

    @Test func insertAndReadStandaloneTranscriptRecord() throws {
        let db = try makeTestDB()

        try db.write { db in
            // Seed the parent audiobook so standalone_transcript's NOT NULL
            // audiobook_id foreign key is satisfied.
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book-1', 'Test', 3600)")
            var record = StandaloneTranscriptRecord(
                id: "seg-1",
                audiobookID: "book-1",
                chapterIndex: 0,
                segmentIndex: 0,
                text: "Hello world.",
                startTime: 0.0,
                endTime: 2.5,
                wordsJSON: nil,
                createdAt: ISO8601DateFormatter().string(from: Date())
            )
            try record.insert(db)
        }

        let count = try db.read { db in
            try StandaloneTranscriptRecord
                .filter(Column("audiobook_id") == "book-1")
                .fetchCount(db)
        }
        #expect(count == 1)
    }

    @Test func insertMultipleSegmentsOrderedByTime() throws {
        let db = try makeTestDB()
        let now = ISO8601DateFormatter().string(from: Date())

        try db.write { db in
            // Parent audiobook for the standalone_transcript foreign key.
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book-1', 'Test', 3600)")
            for i in 0..<5 {
                var record = StandaloneTranscriptRecord(
                    id: "seg-\(i)",
                    audiobookID: "book-1",
                    chapterIndex: 0,
                    segmentIndex: i,
                    text: "Segment \(i).",
                    startTime: Double(i) * 10.0,
                    endTime: Double(i) * 10.0 + 8.0,
                    wordsJSON: nil,
                    createdAt: now
                )
                try record.insert(db)
            }
        }

        let segments = try db.read { db in
            try StandaloneTranscriptRecord
                .filter(Column("audiobook_id") == "book-1")
                .order(Column("start_time").asc)
                .fetchAll(db)
        }
        #expect(segments.count == 5)
        #expect(segments[0].startTime == 0.0)
        #expect(segments[4].startTime == 40.0)
    }

    @Test func standaloneTranscriptTableExists() throws {
        let db = try makeTestDB()

        let tables = try db.read { db in
            try String.fetchAll(
                db,
                sql: """
                    SELECT name FROM sqlite_master
                    WHERE type='table'
                    ORDER BY name
                    """)
        }
        #expect(tables.contains("standalone_transcript"))
    }

    // MARK: - Progress State

    @Test func progressStateInitialValues() {
        let state = StandaloneProgressState()
        #expect(state.chaptersTotal == 0)
        #expect(state.chaptersComplete == 0)
        #expect(state.currentChapterIndex == 0)
        #expect(state.isRunning == false)
        #expect(state.isCancelled == false)
    }

    @Test func serviceInitializesWithDatabase() throws {
        let db = try makeTestDB()
        let service = StandaloneTranscriptionService(db: db)
        #expect(service.progress.isRunning == false)
        #expect(service.progress.isCancelled == false)
    }

    @Test func serviceCancelResetsProgress() throws {
        let db = try makeTestDB()
        let service = StandaloneTranscriptionService(db: db)
        service.progress.isRunning = true
        service.cancel()
        #expect(service.progress.isRunning == false)
        #expect(service.progress.isCancelled == true)
    }

    // MARK: - TranscribedWord Codable

    @Test func transcribedWordEncodingAndDecoding() throws {
        let words = [
            StandaloneTranscribedWord(word: "Hello", start: 0.0, end: 0.5, confidence: 0.95),
            StandaloneTranscribedWord(word: "world.", start: 0.5, end: 1.0, confidence: 0.88),
        ]
        let data = try JSONEncoder().encode(words)
        let decoded = try JSONDecoder().decode([StandaloneTranscribedWord].self, from: data)
        #expect(decoded.count == 2)
        #expect(decoded[0].word == "Hello")
        #expect(decoded[0].start == 0.0)
        #expect(decoded[0].end == 0.5)
        #expect(decoded[1].confidence == 0.88)
    }

    // MARK: - Database Round-trip with Words JSON

    @Test func recordRoundTripWithWordsJSON() throws {
        let db = try makeTestDB()
        let now = ISO8601DateFormatter().string(from: Date())
        let words = [
            StandaloneTranscribedWord(word: "Test", start: 1.0, end: 1.2, confidence: 0.99)
        ]
        let wordsData = try JSONEncoder().encode(words)
        let wordsJSON = String(data: wordsData, encoding: .utf8)

        try db.write { db in
            // Parent audiobook for the standalone_transcript foreign key.
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book-2', 'Test', 3600)")
            var record = StandaloneTranscriptRecord(
                id: "seg-w1",
                audiobookID: "book-2",
                chapterIndex: 1,
                segmentIndex: 0,
                text: "Test",
                startTime: 1.0,
                endTime: 1.2,
                wordsJSON: wordsJSON,
                createdAt: now
            )
            try record.insert(db)
        }

        let fetched = try db.read { db in
            try StandaloneTranscriptRecord.fetchOne(db, key: "seg-w1")
        }
        #expect(fetched != nil)
        #expect(fetched?.wordsJSON != nil)

        let decodedWords = try JSONDecoder().decode(
            [StandaloneTranscribedWord].self,
            from: Data(fetched!.wordsJSON!.utf8)
        )
        #expect(decodedWords.count == 1)
        #expect(decodedWords[0].word == "Test")
    }

    // MARK: - Canonical id (FK) — empty-chapters fast path keys nothing wrong

    @Test func startWithNoChaptersDoesNotRunAndKeepsCanonicalIdSeam() async throws {
        let db = try makeTestDB()
        // Parent keyed by the canonical folder id, NOT the audio file id.
        try await db.write { database in
            try database.execute(
                sql:
                    "INSERT INTO audiobook (id, title, duration, added_at) VALUES ('file:///book/', 'Test', 60, '2026-06-29T00:00:00Z')"
            )
        }
        let service = StandaloneTranscriptionService(db: db)
        await service.start(
            audiobookID: "file:///book/",
            audioFileURL: URL(fileURLWithPath: "/tmp/book/audio.m4b"),
            chapters: [])
        #expect(service.progress.isRunning == false)
        // No chapters → no rows, and crucially the call compiles against the new
        // signature that carries the canonical id separately from the audio URL.
        let count = try await db.read { database in
            try StandaloneTranscriptRecord
                .filter(Column("audiobook_id") == "file:///book/")
                .fetchCount(database)
        }
        #expect(count == 0)
    }

    // MARK: - Resume skip-logic + clear

    private func seedSegmentRow(
        _ db: DatabaseWriter, audiobookID: String, chapterIndex: Int
    ) throws {
        try db.write { database in
            var rec = StandaloneTranscriptRecord(
                id: "seg-\(chapterIndex)", audiobookID: audiobookID,
                chapterIndex: chapterIndex, segmentIndex: 0, text: "x",
                startTime: 0, endTime: 1, wordsJSON: nil,
                createdAt: "2026-06-29T00:00:00Z")
            try rec.insert(database)
        }
    }

    @Test func pauseDoesNotSetCancelled() throws {
        let db = try makeTestDB()
        let service = StandaloneTranscriptionService(db: db)
        service.progress.isRunning = true
        service.pause()
        #expect(service.progress.isCancelled == false)
    }

    @Test func clearTranscriptRemovesRowsAndProjection() async throws {
        let db = try makeTestDB()
        let bookID = "file:///book/"
        try await db.write { database in
            try database.execute(
                sql:
                    "INSERT INTO audiobook (id, title, duration, added_at) VALUES (?, 'T', 60, '2026-06-29T00:00:00Z')",
                arguments: [bookID])
        }
        // Seed one raw segment with a word so the projection has all three tables.
        let words = [StandaloneTranscribedWord(word: "x", start: 0, end: 1, confidence: 0.9)]
        let json = String(data: try JSONEncoder().encode(words), encoding: .utf8)
        try await db.write { database in
            var rec = StandaloneTranscriptRecord(
                id: "seg-0", audiobookID: bookID, chapterIndex: 0, segmentIndex: 0,
                text: "x", startTime: 0, endTime: 1, wordsJSON: json,
                createdAt: "2026-06-29T00:00:00Z")
            try rec.insert(database)
        }
        try await TranscriptMaterializer.materialize(audiobookID: bookID, writer: db)
        #expect(try EPubBlockDAO(db: db).count(for: bookID) == 1)

        let service = StandaloneTranscriptionService(db: db)
        await service.clearTranscript(audiobookID: bookID)

        let raw = try await db.read { database in
            try StandaloneTranscriptRecord
                .filter(Column("audiobook_id") == bookID).fetchCount(database)
        }
        #expect(raw == 0)
        #expect(try EPubBlockDAO(db: db).count(for: bookID) == 0)
        #expect(try TimelineDAO(db: db).items(for: bookID).isEmpty)
        #expect(try WordTimingDAO(db: db).words(forAudiobook: bookID).isEmpty)
    }
}
