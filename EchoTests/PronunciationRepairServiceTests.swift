// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct PronunciationRepairServiceTests {

    /// Seed one audiobook + block so the resolver has a real FK row.
    private func seedBlock(
        audiobookID: String, blockID: String, chapterIndex: Int, db: DatabaseService
    ) throws {
        try db.writer.write { database in
            try database.execute(
                sql:
                    "INSERT INTO audiobook (id, title, duration, added_at) VALUES (?, ?, 0, '2026-01-01T00:00:00Z')",
                arguments: [audiobookID, "Book"])
        }
        var block = EPubBlockRecord(
            id: blockID, audiobookID: audiobookID, spineHref: "ch.xhtml",
            spineIndex: 0, blockIndex: 0, sequenceIndex: 0,
            blockKind: EPubBlockRecord.Kind.paragraph.rawValue,
            text: "Hello Arrakis.", htmlContent: nil, cardColor: nil,
            chapterThemeColor: nil, imagePath: nil, chapterIndex: chapterIndex,
            isHidden: false, hiddenReason: nil, isFrontMatter: false,
            wordCount: 2, markers: nil, textFormats: nil,
            createdAt: nil, modifiedAt: nil)
        try EPubBlockDAO(db: db.writer).insert(block)
        _ = block  // silence unused-var if insert copies
    }

    @Test func resolvesChapterIndexForBlock() throws {
        let db = try DatabaseService(inMemory: ())
        let bookID = "file:///Books/Dune/"
        try seedBlock(audiobookID: bookID, blockID: "epub-\(bookID)-s0-b0", chapterIndex: 7, db: db)

        let idx = try PronunciationRepairService.chapterIndex(
            forBlockID: "epub-\(bookID)-s0-b0", audiobookID: bookID, db: db.writer)
        #expect(idx == 7)
    }

    @Test func returnsNilForUnknownBlock() throws {
        let db = try DatabaseService(inMemory: ())
        let idx = try PronunciationRepairService.chapterIndex(
            forBlockID: "nope", audiobookID: "file:///Books/Dune/", db: db.writer)
        #expect(idx == nil)
    }

    // MARK: - applyFix

    @MainActor
    @Test func applyFixWritesPerBookOverrideAndResolvesIssue() async throws {
        let db = try DatabaseService(inMemory: ())
        let bookID = "file:///Books/Dune/"
        let blockID = "epub-\(bookID)-s0-b0"
        try seedBlock(audiobookID: bookID, blockID: blockID, chapterIndex: 3, db: db)

        // Persist an open issue with a suggested IPA fix for "Arrakis".
        let fix = SuggestedFix(spokenForm: "Arrakis", ipa: "ɑˈɹɑːkɪs")
        let fixJSON = String(data: try JSONEncoder().encode(fix), encoding: .utf8)
        let issue = NarrationQualityIssueRecord(
            id: "iss-1", audiobookID: bookID, sourceBlockID: blockID,
            sourceWordStart: 1, sourceWordEnd: 1,
            audioStartTime: 0, audioEndTime: 2,
            expectedText: "Arrakis", heardText: "a rockis",
            issueType: NarrationQAIssueType.pronunciation.rawValue,
            confidence: 0.4, suggestedFixJSON: fixJSON,
            status: NarrationQAIssueStatus.open.rawValue,
            createdAt: "2026-06-29T00:00:00Z", resolvedAt: nil)
        let issueDAO = NarrationQualityIssueDAO(db: db.writer)
        try issueDAO.insert([issue])

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = PronunciationOverrideStore(directory: tmp)

        var renderedChapters: [Int] = []
        var reQAChapters: [Int] = []
        let svc = PronunciationRepairService(
            store: store, issueDAO: issueDAO, db: db.writer,
            cacheDirectory: tmp, voice: VoiceCatalog.default.id,
            renderChapter: { chapterIndex in renderedChapters.append(chapterIndex) },
            reRunQA: { chapterIndex in reQAChapters.append(chapterIndex) })

        try await svc.applyFix(issue: issue, scope: .book(bookID))

        // Override written, book-scoped.
        #expect(store.overrides(forBookID: bookID).entries["Arrakis"] == "ɑˈɹɑːkɪs")
        // The chapter containing the block (3) was regenerated and re-QA'd.
        #expect(renderedChapters == [3])
        #expect(reQAChapters == [3])
        // Issue resolved + persisted.
        let resolved = try issueDAO.issues(
            for: bookID, status: NarrationQAIssueStatus.resolved.rawValue)
        #expect(resolved.contains { $0.id == "iss-1" })
        #expect(
            try issueDAO.issues(for: bookID, status: NarrationQAIssueStatus.open.rawValue).isEmpty)
    }

    @MainActor
    @Test func applyFixGlobalScopeWritesGlobalOverride() async throws {
        let db = try DatabaseService(inMemory: ())
        let bookID = "file:///Books/Dune/"
        let blockID = "epub-\(bookID)-s0-b0"
        try seedBlock(audiobookID: bookID, blockID: blockID, chapterIndex: 0, db: db)
        let fix = SuggestedFix(spokenForm: nil, ipa: "θˈɛstɹəl")
        let issue = NarrationQualityIssueRecord(
            id: "iss-2", audiobookID: bookID, sourceBlockID: blockID,
            sourceWordStart: 0, sourceWordEnd: 0, audioStartTime: 0, audioEndTime: 1,
            expectedText: "Thestral", heardText: "thestrel",
            issueType: NarrationQAIssueType.pronunciation.rawValue,
            confidence: 0.4,
            suggestedFixJSON: String(data: try JSONEncoder().encode(fix), encoding: .utf8),
            status: NarrationQAIssueStatus.open.rawValue,
            createdAt: "2026-06-29T00:00:00Z", resolvedAt: nil)
        let issueDAO = NarrationQualityIssueDAO(db: db.writer)
        try issueDAO.insert([issue])
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = PronunciationOverrideStore(directory: tmp)
        let svc = PronunciationRepairService(
            store: store, issueDAO: issueDAO, db: db.writer,
            cacheDirectory: tmp, voice: VoiceCatalog.default.id,
            renderChapter: { _ in }, reRunQA: { _ in })

        try await svc.applyFix(issue: issue, scope: .global)
        #expect(store.entries["Thestral"] == "θˈɛstɹəl")
        // Book-scoped lookup also sees it (global is the base of the merge).
        #expect(store.overrides(forBookID: bookID).entries["Thestral"] == "θˈɛstɹəl")
    }
}
