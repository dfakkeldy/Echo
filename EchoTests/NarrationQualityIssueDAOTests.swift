// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor @Suite struct NarrationQualityIssueDAOTests {
    private func seedBook(_ id: String, db: DatabaseService) throws {
        try db.writer.write { database in
            try database.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES (?, ?, ?)",
                arguments: [id, "Test", 3600.0])
        }
    }

    private func make(
        _ id: String,
        book: String,
        status: String,
        blockID: String = "blk1",
        origin: NarrationQualityIssueOrigin = .asr
    ) -> NarrationQualityIssueRecord {
        NarrationQualityIssueRecord(
            id: id, audiobookID: book, sourceBlockID: blockID,
            sourceWordStart: 2, sourceWordEnd: 3, audioStartTime: 1.0, audioEndTime: 2.0,
            expectedText: "colonel", heardText: "kernel",
            issueType: NarrationQAIssueType.substitution.rawValue, confidence: 0.8,
            suggestedFixJSON: nil, origin: origin.rawValue, evidenceJSON: nil, status: status,
            createdAt: "2026-06-29T00:00:00Z", resolvedAt: nil)
    }

    private func advisoryRecords(for blockID: String, wordStart: Int) -> [NarrationQualityIssueRecord] {
        let evidence = PronunciationAdvisoryEvidence(
            category: .lexical,
            selectedAuthority: .qualified,
            selectedCandidateID: "candidate.content",
            alternatives: [
                .init(
                    candidateID: "candidate.content",
                    ipa: "kˈɑntɛnt",
                    source: "fixture",
                    authority: .qualified,
                    validation: .shadow,
                    policyVersion: "policy-v1")
            ],
            selectionReason: .shadowCandidate,
            overrideSuppressedAutomation: false,
            policyVersion: "policy-v1")
        let decision = PronunciationAuditDecision(
            blockID: blockID,
            wordStart: wordStart,
            wordEnd: wordStart,
            normalizedWord: "content",
            sourceWord: "content",
            sourceContext: "private source context",
            selectedIPA: "kˈɑntɛnt",
            kokoroTokenIDs: [1],
            source: .supplementalLexicon,
            ruleID: "private-rule",
            rationale: "private rationale",
            candidateID: "candidate.content",
            advisoryEvidence: evidence)
        return PronunciationAdvisoryIssueBuilder().records(
            audiobookID: "b1",
            decisions: [decision],
            diagnostics: [],
            createdAt: "t0")
    }

    @Test func insertsAndFetchesByBook() throws {
        let db = try DatabaseService(inMemory: ())
        try seedBook("b1", db: db)
        let dao = NarrationQualityIssueDAO(db: db.writer)
        try dao.insert([
            make("i1", book: "b1", status: "open"), make("i2", book: "b1", status: "open"),
        ])
        #expect(try dao.issues(for: "b1").count == 2)
    }

    @Test func filtersByStatusAndUpdatesStatus() throws {
        let db = try DatabaseService(inMemory: ())
        try seedBook("b1", db: db)
        let dao = NarrationQualityIssueDAO(db: db.writer)
        try dao.insert([make("i1", book: "b1", status: "open")])
        try dao.updateStatus(id: "i1", status: "resolved", resolvedAt: "2026-06-29T01:00:00Z")
        #expect(try dao.issues(for: "b1", status: "open").isEmpty)
        #expect(try dao.issues(for: "b1", status: "resolved").count == 1)
    }

    @Test func deletesByBookAndByBlockIDs() throws {
        let db = try DatabaseService(inMemory: ())
        try seedBook("b1", db: db)
        let dao = NarrationQualityIssueDAO(db: db.writer)
        try dao.insert([make("i1", book: "b1", status: "open")])
        try dao.deleteAll(for: "b1", blockIDs: ["blk1"])
        #expect(try dao.issues(for: "b1").isEmpty)
        try dao.insert([make("i2", book: "b1", status: "open")])
        try dao.deleteAll(for: "b1")
        #expect(try dao.issues(for: "b1").isEmpty)
    }

    @Test func replaceOpenScopesDeletionToTheRequestedOriginAndBlocks() throws {
        let db = try DatabaseService(inMemory: ())
        try seedBook("b1", db: db)
        try seedBook("b2", db: db)
        let dao = NarrationQualityIssueDAO(db: db.writer)
        try dao.insert([
            make("asr-open", book: "b1", status: "open", origin: .asr),
            make("preflight-open", book: "b1", status: "open", origin: .pronunciationPreflight),
            make("acoustic-open", book: "b1", status: "open", origin: .acoustic),
            make("asr-resolved", book: "b1", status: "resolved", origin: .asr),
            make("asr-other-block", book: "b1", status: "open", blockID: "blk2", origin: .asr),
            make("asr-other-book", book: "b2", status: "open", origin: .asr),
        ])

        try dao.replaceOpen(
            for: "b1",
            blockIDs: ["blk1"],
            origin: .asr,
            with: [make("asr-fresh", book: "b1", status: "open", origin: .asr)])

        let b1 = try dao.issues(for: "b1")
        #expect(!b1.contains { $0.id == "asr-open" })
        #expect(b1.contains { $0.id == "asr-fresh" })
        #expect(b1.contains { $0.id == "preflight-open" })
        #expect(b1.contains { $0.id == "acoustic-open" })
        #expect(b1.contains { $0.id == "asr-resolved" })
        #expect(b1.contains { $0.id == "asr-other-block" })
        #expect(try dao.issues(for: "b2").contains { $0.id == "asr-other-book" })
    }

    @Test func replacementRejectsRecordsFromAnotherOrigin() throws {
        let db = try DatabaseService(inMemory: ())
        try seedBook("b1", db: db)
        let dao = NarrationQualityIssueDAO(db: db.writer)

        #expect(throws: NarrationQualityIssueDAOError.self) {
            try dao.replaceOpen(
                for: "b1",
                blockIDs: ["blk1"],
                origin: .asr,
                with: [
                    make(
                        "wrong-origin",
                        book: "b1",
                        status: "open",
                        origin: .pronunciationPreflight)
                ])
        }
    }

    @Test func sequentialNonContextualUnitsDoNotCollideAndZeroRefreshRemovesOnlyItsUnit()
        throws
    {
        let db = try DatabaseService(inMemory: ())
        try seedBook("b1", db: db)
        let dao = NarrationQualityIssueDAO(db: db.writer)
        let firstUnit = advisoryRecords(for: "blk1", wordStart: 1)
        let secondUnit = advisoryRecords(for: "blk2", wordStart: 4)
        #expect(firstUnit.map(\.id) != secondUnit.map(\.id))

        try dao.replaceOpen(
            for: "b1",
            blockIDs: ["blk1"],
            origin: .pronunciationPreflight,
            with: firstUnit)
        try dao.replaceOpen(
            for: "b1",
            blockIDs: ["blk2"],
            origin: .pronunciationPreflight,
            with: secondUnit)
        try dao.replaceOpen(
            for: "b1",
            blockIDs: ["blk1"],
            origin: .pronunciationPreflight,
            with: [])

        let open = try dao.issues(for: "b1", status: NarrationQAIssueStatus.open.rawValue)
        #expect(open.map(\.id) == secondUnit.map(\.id))
    }

    @Test func rangeFreeDiagnosticPersistsAndAZeroRefreshClearsItsAuditedBlock() throws {
        let db = try DatabaseService(inMemory: ())
        try seedBook("b1", db: db)
        let dao = NarrationQualityIssueDAO(db: db.writer)
        let diagnostic = PronunciationAuditDiagnostic(
            reason: .decisionEvidenceMismatch,
            blockID: "invalid-g2p",
            chunkIndex: -1,
            expectedDisplayText: "private source text",
            reconstructedSpokenSurface: "",
            fallbackHits: [])
        let records = PronunciationAdvisoryIssueBuilder().records(
            audiobookID: "b1", decisions: [], diagnostics: [diagnostic], createdAt: "t0")

        // `spokenBlockIDs` is empty for an all-invalid G2P plan, but its audited
        // source block remains the replacement scope for durable advisories.
        try dao.replaceOpen(
            for: "b1",
            blockIDs: ["invalid-g2p"],
            origin: .pronunciationPreflight,
            with: records)
        #expect(try dao.issues(for: "b1").map(\.id) == records.map(\.id))

        try dao.replaceOpen(
            for: "b1",
            blockIDs: ["invalid-g2p"],
            origin: .pronunciationPreflight,
            with: [])
        #expect(try dao.issues(for: "b1").isEmpty)
    }
}
