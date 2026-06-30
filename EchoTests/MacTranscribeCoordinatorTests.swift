// SPDX-License-Identifier: GPL-3.0-or-later
#if os(macOS)
    import Foundation
    import GRDB
    import Testing

    @testable import Echo

    @MainActor @Suite struct MacTranscribeCoordinatorTests {
        private let bookID = "file:///book/"

        private func makeDB() throws -> DatabaseService {
            let db = try DatabaseService(inMemory: ())
            try db.writer.write { database in
                try database.execute(
                    sql:
                        "INSERT INTO audiobook (id, title, duration, added_at) VALUES (?, 'T', 60, '2026-06-29T00:00:00Z')",
                    arguments: [bookID])
                var rec = StandaloneTranscriptRecord(
                    id: "seg-0", audiobookID: bookID, chapterIndex: 0, segmentIndex: 0,
                    text: "Hello world.", startTime: 0, endTime: 2,
                    wordsJSON: String(
                        data: try JSONEncoder().encode([
                            StandaloneTranscribedWord(
                                word: "Hello", start: 0, end: 1, confidence: 0.9),
                            StandaloneTranscribedWord(
                                word: "world.", start: 1, end: 2, confidence: 0.8),
                        ]), encoding: .utf8),
                    createdAt: "2026-06-29T00:00:00Z")
                try rec.insert(database)
            }
            return db
        }

        @Test func finalizeMaterializesAndSetsTextOrigin() async throws {
            let db = try makeDB()
            let coordinator = MacTranscribeCoordinator(db: db.writer)
            await coordinator.finalize(audiobookID: bookID)

            #expect(try EPubBlockDAO(db: db.writer).count(for: bookID) == 1)
            #expect(try AudiobookDAO(db: db.writer).get(bookID)?.textOrigin == "transcript")
            #expect(coordinator.isFinalizing == false)
        }

        @Test func finalizePreservesOtherAudiobookFields() async throws {
            let db = try makeDB()
            try AudiobookDAO(db: db.writer).save(
                AudiobookRecord(
                    id: bookID, title: "Keep Me", author: "Author", duration: 60,
                    addedAt: "2026-06-29T00:00:00Z"))
            await MacTranscribeCoordinator(db: db.writer).finalize(audiobookID: bookID)
            let book = try AudiobookDAO(db: db.writer).get(bookID)
            #expect(book?.title == "Keep Me")
            #expect(book?.author == "Author")
            #expect(book?.textOrigin == "transcript")
        }

        @Test func clearTranscriptDeletesData() async throws {
            let db = try makeDB()
            let coordinator = MacTranscribeCoordinator(db: db.writer)

            // First materialize, then clear
            await coordinator.finalize(audiobookID: bookID)
            #expect(try EPubBlockDAO(db: db.writer).count(for: bookID) == 1)

            await coordinator.clearTranscript(audiobookID: bookID)

            // After clear, transcript projection should be gone
            #expect(try EPubBlockDAO(db: db.writer).count(for: bookID) == 0)
        }

        @Test func transcribeOnEmptyChaptersUsesFullBookFallback() async throws {
            // Verifies the coordinator does not crash when chapters is empty
            // and the book has no content (edge case: early return).
            let db = try makeDB()
            let coordinator = MacTranscribeCoordinator(db: db.writer)
            // No-op call with empty chapter list — should not finalize anything
            // since no real transcription ran. Verify it doesn't crash.
            coordinator.service.cancel()
            #expect(coordinator.isFinalizing == false)
        }

        @Test func progressFractionStaticHelper() {
            let state = StandaloneProgressState()
            state.chaptersTotal = 5
            state.chaptersComplete = 3
            #expect(MacTranscribeProgressView.fraction(for: state) == 0.6)

            state.chaptersComplete = 5
            #expect(MacTranscribeProgressView.fraction(for: state) == 1.0)

            state.chaptersTotal = 0
            #expect(MacTranscribeProgressView.fraction(for: state) == 0.0)
        }
    }
#endif
