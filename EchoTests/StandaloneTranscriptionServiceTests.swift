import Testing
import Foundation
import GRDB
@testable import Echo

@MainActor
struct StandaloneTranscriptionServiceTests {

    /// Creates an in-memory database with all schema migrations applied.
    private func makeTestDB() throws -> DatabaseWriter {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys=ON")
        }
        let queue = try DatabaseQueue(path: ":memory:", configuration: config)
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in try Schema_V1.migrate(db) }
        migrator.registerMigration("v2") { db in try Schema_V2.migrate(db) }
        migrator.registerMigration("v3") { db in try Schema_V3.migrate(db) }
        migrator.registerMigration("v4") { db in try Schema_V4.migrate(db) }
        migrator.registerMigration("v5") { db in try Schema_V5.migrate(db) }
        migrator.registerMigration("v6") { db in try Schema_V6.migrate(db) }
        migrator.registerMigration("v7") { db in try Schema_V7.migrate(db) }
        migrator.registerMigration("v8") { db in try Schema_V8.migrate(db) }
        migrator.registerMigration("v9") { db in try Schema_V9.migrate(db) }
        migrator.registerMigration("v10") { db in try Schema_V10.migrate(db) }
        migrator.registerMigration("v11") { db in try Schema_V11.migrate(db) }
        migrator.registerMigration("v12") { db in try Schema_V12.migrate(db) }
        migrator.registerMigration("v13") { db in try Schema_V13.migrate(db) }
        migrator.registerMigration("v14") { db in try Schema_V14.migrate(db) }
        migrator.registerMigration("v15") { db in try Schema_V15.migrate(db) }
        migrator.registerMigration("v16") { db in try Schema_V16.migrate(db) }
        try migrator.migrate(queue)
        return queue
    }

    // MARK: - Record Persistence

    @Test func insertAndReadStandaloneTranscriptRecord() throws {
        let db = try makeTestDB()

        try db.write { db in
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
            try String.fetchAll(db, sql: """
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
            StandaloneTranscribedWord(word: "world.", start: 0.5, end: 1.0, confidence: 0.88)
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
}
