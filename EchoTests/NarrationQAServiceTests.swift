// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor @Suite struct NarrationQAServiceTests {
    private struct TranscriptionFailure: Error {}

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

    private func seedOpenIssue(_ db: DatabaseService, book: String, id: String) throws {
        try NarrationQualityIssueDAO(db: db.writer).insert([
            NarrationQualityIssueRecord(
                id: id, audiobookID: book, sourceBlockID: "blk1",
                sourceWordStart: 0, sourceWordEnd: 0,
                audioStartTime: 0, audioEndTime: 1,
                expectedText: "quick", heardText: "",
                issueType: NarrationQAIssueType.omission.rawValue,
                confidence: 1.0, suggestedFixJSON: nil,
                status: NarrationQAIssueStatus.open.rawValue,
                createdAt: "t0", resolvedAt: nil)
        ])
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

    @Test func reRunPreservesResolvedAndIgnoredAuditHistory() async throws {
        let db = try DatabaseService(inMemory: ())
        try seed(db, book: "b1")
        let dao = NarrationQualityIssueDAO(db: db.writer)
        // The user already triaged two prior issues on this chapter's block.
        let resolved = NarrationQualityIssueRecord(
            id: "resolved-1", audiobookID: "b1", sourceBlockID: "blk1",
            sourceWordStart: 7, sourceWordEnd: 7, audioStartTime: 2.4, audioEndTime: 2.6,
            expectedText: "lazy", heardText: "",
            issueType: NarrationQAIssueType.pronunciation.rawValue, confidence: 1.0,
            suggestedFixJSON: nil, status: NarrationQAIssueStatus.resolved.rawValue,
            createdAt: "t0", resolvedAt: "t1")
        let ignored = NarrationQualityIssueRecord(
            id: "ignored-1", audiobookID: "b1", sourceBlockID: "blk1",
            sourceWordStart: 3, sourceWordEnd: 3, audioStartTime: 1.0, audioEndTime: 1.2,
            expectedText: "fox", heardText: "",
            issueType: NarrationQAIssueType.omission.rawValue, confidence: 1.0,
            suggestedFixJSON: nil, status: NarrationQAIssueStatus.ignored.rawValue,
            createdAt: "t0", resolvedAt: nil)
        try dao.insert([resolved, ignored])

        // A fresh QA pass that drops words on the same block.
        let heard: [TranscribedWord] = [("the", 0.0), ("quick", 0.4), ("dog", 0.8)]
            .map { TranscribedWord(text: $0.0, start: $0.1) }
        let service = NarrationQAService(
            db: db.writer, classifier: DeterministicDivergenceClassifier(),
            transcribe: { _ in heard })
        try await service.runQA(
            audiobookID: "b1",
            chapters: [(0, URL(fileURLWithPath: "/tmp/x.m4a"), ["blk1"])])

        let all = try dao.issues(for: "b1")
        // The user's prior verdicts survive the re-run (audit history is not destroyed).
        #expect(all.contains { $0.id == "resolved-1" && $0.status == "resolved" })
        #expect(all.contains { $0.id == "ignored-1" && $0.status == "ignored" })
        // …and fresh open issues are still produced by the re-QA.
        #expect(all.contains { $0.status == NarrationQAIssueStatus.open.rawValue })
    }

    @Test func chaptersToQAIncludesOnlyRenderedChaptersWithNonHiddenBlocks() {
        func mk(_ id: String, chapter: Int, hidden: Bool) -> EPubBlockRecord {
            EPubBlockRecord(
                id: id, audiobookID: "b1", spineHref: "s.html", spineIndex: 0, blockIndex: 0,
                sequenceIndex: 0, blockKind: EPubBlockRecord.Kind.paragraph.rawValue, text: "hi",
                htmlContent: nil, cardColor: nil, chapterThemeColor: nil, imagePath: nil,
                chapterIndex: chapter, isHidden: hidden, hiddenReason: nil, wordCount: 1,
                markers: nil, textFormats: nil, createdAt: nil, modifiedAt: nil)
        }
        let blocksByChapter: [Int: [EPubBlockRecord]] = [
            0: [mk("b0a", chapter: 0, hidden: false), mk("b0b", chapter: 0, hidden: false)],
            1: [mk("b1a", chapter: 1, hidden: false)],  // rendered file is MISSING
            2: [mk("b2h", chapter: 2, hidden: true)],  // rendered but only hidden blocks
        ]
        let urlFor: (Int) -> URL = { URL(fileURLWithPath: "/tmp/ch\($0).m4a") }
        let rendered: Set<URL> = [urlFor(0), urlFor(2)]

        let result = NarrationQAService.chaptersToQA(
            blocksByChapter: blocksByChapter, fileURL: urlFor,
            fileExists: { rendered.contains($0) })

        // Only chapter 0 qualifies (rendered AND has non-hidden blocks).
        #expect(result.count == 1)
        #expect(result.first?.chapterIndex == 0)
        #expect(result.first?.spokenBlockIDs == ["b0a", "b0b"])
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

    @Test func insertedHeardWordsPersistAsInsertionIssues() async throws {
        let db = try DatabaseService(inMemory: ())
        try seed(db, book: "b1", text: "quick brown fox")
        let heard: [TranscribedWord] = [
            ("quick", 0.0), ("very", 0.4), ("brown", 0.8), ("fox", 1.2),
        ].map { TranscribedWord(text: $0.0, start: $0.1) }
        let service = NarrationQAService(
            db: db.writer, classifier: DeterministicDivergenceClassifier(),
            transcribe: { _ in heard })

        try await service.runQA(
            audiobookID: "b1", chapters: [(0, URL(fileURLWithPath: "/tmp/x.m4a"), ["blk1"])])

        let issues = try NarrationQualityIssueDAO(db: db.writer).issues(for: "b1")
        #expect(issues.count == 1)
        #expect(issues.first?.issueType == NarrationQAIssueType.insertion.rawValue)
        #expect(issues.first?.expectedText == "")
        #expect(issues.first?.heardText == "very")
    }

    @Test func lowConfidenceMatchedWordsPersistAsLowConfidenceIssues() async throws {
        let db = try DatabaseService(inMemory: ())
        try seed(db, book: "b1", text: "quick brown fox")
        let heard: [TranscribedWord] = [
            TranscribedWord(text: "quick", start: 0.0, confidence: 1.0),
            TranscribedWord(text: "brawn", start: 0.4, confidence: 0.25),
            TranscribedWord(text: "fox", start: 0.8, confidence: 1.0),
        ]
        let service = NarrationQAService(
            db: db.writer, classifier: DeterministicDivergenceClassifier(),
            transcribe: { _ in heard })

        try await service.runQA(
            audiobookID: "b1", chapters: [(0, URL(fileURLWithPath: "/tmp/x.m4a"), ["blk1"])])

        let issues = try NarrationQualityIssueDAO(db: db.writer).issues(for: "b1")
        #expect(issues.count == 1)
        #expect(issues.first?.issueType == NarrationQAIssueType.lowConfidence.rawValue)
        #expect(issues.first?.expectedText == "brown")
        #expect(issues.first?.heardText == "brawn")
        #expect(issues.first?.confidence == 0.25)
    }

    @Test func transcriptionFailureThrowsAndPreservesOpenIssues() async throws {
        let db = try DatabaseService(inMemory: ())
        try seed(db, book: "b1")
        try seedOpenIssue(db, book: "b1", id: "old-open")
        let service = NarrationQAService(
            db: db.writer, classifier: DeterministicDivergenceClassifier(),
            transcribe: { _ in throw TranscriptionFailure() })

        do {
            try await service.runQA(
                audiobookID: "b1",
                chapters: [(0, URL(fileURLWithPath: "/tmp/x.m4a"), ["blk1"])])
            Issue.record("Expected transcription failure to throw")
        } catch let error as NarrationQAError {
            if case .transcriptionFailed(let chapterIndex, _, _) = error {
                #expect(chapterIndex == 0)
            } else {
                Issue.record("Expected transcriptionFailed, got \(error)")
            }
        } catch {
            Issue.record("Expected NarrationQAError, got \(error)")
        }

        let open = try NarrationQualityIssueDAO(db: db.writer)
            .issues(for: "b1", status: NarrationQAIssueStatus.open.rawValue)
        #expect(open.contains { $0.id == "old-open" })
    }

    @Test func noHeardWordsThrowsDistinctErrorAndPreservesOpenIssues() async throws {
        let db = try DatabaseService(inMemory: ())
        try seed(db, book: "b1")
        try seedOpenIssue(db, book: "b1", id: "old-open")
        let service = NarrationQAService(
            db: db.writer, classifier: DeterministicDivergenceClassifier(),
            transcribe: { _ in [] })

        do {
            try await service.runQA(
                audiobookID: "b1",
                chapters: [(0, URL(fileURLWithPath: "/tmp/x.m4a"), ["blk1"])])
            Issue.record("Expected no-heard-words to throw")
        } catch let error as NarrationQAError {
            if case .noHeardWords(let chapterIndex, _) = error {
                #expect(chapterIndex == 0)
            } else {
                Issue.record("Expected noHeardWords, got \(error)")
            }
        } catch {
            Issue.record("Expected NarrationQAError, got \(error)")
        }

        let open = try NarrationQualityIssueDAO(db: db.writer)
            .issues(for: "b1", status: NarrationQAIssueStatus.open.rawValue)
        #expect(open.contains { $0.id == "old-open" })
    }
}
