// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS)
    import Foundation
    import GRDB
    import Testing

    @testable import Echo

    @MainActor @Suite struct TranscribeBookCoordinatorTests {
        private let bookID = "file:///book/"

        private func makeDB(transcriptChapterIndices: [Int] = [0]) throws -> DatabaseService {
            let db = try DatabaseService(inMemory: ())
            try db.writer.write { database in
                try database.execute(
                    sql:
                        "INSERT INTO audiobook (id, title, duration, added_at) VALUES (?, 'T', 60, '2026-06-29T00:00:00Z')",
                    arguments: [bookID])
                for chapterIndex in transcriptChapterIndices {
                    let startTime = Double(chapterIndex * 10)
                    var rec = StandaloneTranscriptRecord(
                        id: "seg-\(chapterIndex)", audiobookID: bookID,
                        chapterIndex: chapterIndex, segmentIndex: 0,
                        text: "Chapter \(chapterIndex + 1).", startTime: startTime,
                        endTime: startTime + 2,
                        wordsJSON: String(
                            data: try JSONEncoder().encode([
                                StandaloneTranscribedWord(
                                    word: "Chapter", start: startTime, end: startTime + 1,
                                    confidence: 0.9),
                                StandaloneTranscribedWord(
                                    word: "\(chapterIndex + 1).", start: startTime + 1,
                                    end: startTime + 2, confidence: 0.8),
                            ]), encoding: .utf8),
                        createdAt: "2026-06-29T00:00:00Z")
                    try rec.insert(database)
                }
            }
            return db
        }

        @Test func finalizeMaterializesAndSetsTextOrigin() async throws {
            let db = try makeDB()
            let coordinator = TranscribeBookCoordinator(db: db.writer)
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
            await TranscribeBookCoordinator(db: db.writer).finalize(audiobookID: bookID)
            let book = try AudiobookDAO(db: db.writer).get(bookID)
            #expect(book?.title == "Keep Me")
            #expect(book?.author == "Author")
            #expect(book?.textOrigin == "transcript")
        }

        @Test func multiChapterTranscribeFinalizesAfterBackgroundCompletes() async throws {
            // Regression guard for the finalize race: for >1 chapter, start() launches
            // chapters 1...n in a detached task and returns while isRunning is still
            // true. transcribe() must await full completion and THEN finalize — not
            // skip finalize because isRunning was sampled mid-flight.
            let db = try makeDB(transcriptChapterIndices: [0, 1])
            let coordinator = TranscribeBookCoordinator(db: db.writer)
            let badURL = URL(fileURLWithPath: "/nonexistent/echo-qa-audio.m4a")
            let chapters = [
                Chapter(index: 0, title: "One", startSeconds: 0, endSeconds: 10),
                Chapter(index: 1, title: "Two", startSeconds: 10, endSeconds: 20),
            ]
            await coordinator.transcribe(
                audiobookID: bookID, audioFileURL: badURL, chapters: chapters, resume: true)

            #expect(try EPubBlockDAO(db: db.writer).count(for: bookID) == 2)
            #expect(try AudiobookDAO(db: db.writer).get(bookID)?.textOrigin == "transcript")
        }

        @Test func multiChapterTranscribeDoesNotFinalizePartialTranscript() async throws {
            let db = try makeDB(transcriptChapterIndices: [0])
            let coordinator = TranscribeBookCoordinator(db: db.writer)
            let badURL = URL(fileURLWithPath: "/nonexistent/echo-qa-audio.m4a")
            let chapters = [
                Chapter(index: 0, title: "One", startSeconds: 0, endSeconds: 10),
                Chapter(index: 1, title: "Two", startSeconds: 10, endSeconds: 20),
            ]

            await coordinator.transcribe(
                audiobookID: bookID, audioFileURL: badURL, chapters: chapters, resume: true)

            #expect(try EPubBlockDAO(db: db.writer).count(for: bookID) == 0)
            #expect(try AudiobookDAO(db: db.writer).get(bookID)?.textOrigin != "transcript")
        }
    }
#endif
