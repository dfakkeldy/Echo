// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor @Suite struct NarrationQAServiceTests {
    private func seed(
        _ db: DatabaseService,
        book: String,
        text: String = "the quick brown fox jumps over the lazy dog"
    ) throws {
        try db.writer.write { database in
            try database.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES (?, ?, ?)",
                arguments: [book, "Test", 3600.0])
        }
        // One source block whose words the narrator will partly drop/swap.
        let dao = EPubBlockDAO(db: db.writer)
        try dao.insert(
            EPubBlockRecord(
                id: "blk1", audiobookID: book, spineHref: "s.html", spineIndex: 0, blockIndex: 0,
                sequenceIndex: 0, blockKind: EPubBlockRecord.Kind.paragraph.rawValue,
                text: text, htmlContent: nil,
                cardColor: nil, chapterThemeColor: nil, imagePath: nil, chapterIndex: 0,
                isHidden: false, hiddenReason: nil, wordCount: 9, markers: nil, textFormats: nil,
                createdAt: nil, modifiedAt: nil))
    }

    @Test func plantedErrorProducesIssueDeterministically() async throws {
        let db = try DatabaseService(inMemory: ())
        try seed(db, book: "b1")
        // "brown" omitted, "lazy" -> "crazy".
        let heard: [TranscribedWord] = [
            ("the", 0.0), ("quick", 0.4), ("fox", 0.8), ("jumps", 1.2), ("over", 1.6),
            ("the", 2.0), ("crazy", 2.4), ("dog", 2.8),
        ].map { TranscribedWord(text: $0.0, start: $0.1) }

        let service = NarrationQAService(
            db: db.writer, classifier: DeterministicDivergenceClassifier(),
            transcribe: { _ in heard })

        let fileURL = URL(fileURLWithPath: "/tmp/does-not-matter.m4a")
        try await service.runQA(
            audiobookID: "b1",
            chapters: [(chapterIndex: 0, fileURL: fileURL, spokenBlockIDs: ["blk1"])])

        let issues = try NarrationQualityIssueDAO(db: db.writer).issues(for: "b1")
        #expect(!issues.isEmpty)
        #expect(issues.allSatisfy { $0.status == NarrationQAIssueStatus.open.rawValue })
        #expect(issues.allSatisfy { $0.sourceBlockID == "blk1" })
    }

    @Test func reRunReplacesPriorIssuesForBlock() async throws {
        let db = try DatabaseService(inMemory: ())
        try seed(db, book: "b1")
        let heard: [TranscribedWord] = [("the", 0.0), ("quick", 0.4), ("dog", 0.8)]
            .map { TranscribedWord(text: $0.0, start: $0.1) }
        let service = NarrationQAService(
            db: db.writer, classifier: DeterministicDivergenceClassifier(),
            transcribe: { _ in heard })
        let fileURL = URL(fileURLWithPath: "/tmp/x.m4a")
        try await service.runQA(
            audiobookID: "b1", chapters: [(0, fileURL, ["blk1"])])
        let firstCount = try NarrationQualityIssueDAO(db: db.writer).issues(for: "b1").count
        try await service.runQA(
            audiobookID: "b1", chapters: [(0, fileURL, ["blk1"])])
        let secondCount = try NarrationQualityIssueDAO(db: db.writer).issues(for: "b1").count
        #expect(firstCount == secondCount)  // cleared + rewritten, not doubled
    }

    @Test func comparesAgainstNarrationNormalizedText() async throws {
        let db = try DatabaseService(inMemory: ())
        try seed(db, book: "b1", text: "Dr. Smith arrived.")
        let heard: [TranscribedWord] = [
            ("doctor", 0.0), ("smith", 0.4), ("arrived", 0.8),
        ].map { TranscribedWord(text: $0.0, start: $0.1) }
        let service = NarrationQAService(
            db: db.writer, classifier: DeterministicDivergenceClassifier(),
            transcribe: { _ in heard })
        let fileURL = URL(fileURLWithPath: "/tmp/x.m4a")

        try await service.runQA(
            audiobookID: "b1", chapters: [(0, fileURL, ["blk1"])])

        let issues = try NarrationQualityIssueDAO(db: db.writer).issues(for: "b1")
        #expect(issues.isEmpty)
    }
}
