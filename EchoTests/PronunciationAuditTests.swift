// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct PronunciationAuditTests {
    private func decision(
        word: String,
        ruleID: String,
        chapterIndex: Int,
        range: PronunciationAuditDecision.AudioRange? = .init(start: 1, end: 1.4)
    ) -> PronunciationAuditDecision {
        PronunciationAuditDecision(
            blockID: "s\(chapterIndex)-b0",
            wordStart: 2,
            wordEnd: 2,
            normalizedWord: word,
            sourceWord: word,
            sourceContext: "The result was \(word) in this bounded context",
            selectedIPA: "ipa-\(word)",
            kokoroTokenIDs: [11, 22, 33],
            source: .monitoredLexicon,
            ruleID: ruleID,
            rationale: "A stable test rationale for \(word).",
            chapterIndex: chapterIndex,
            chapterRelativeAudioRange: range,
            bookRelativeAudioRange: range.map {
                .init(start: Double(chapterIndex * 10) + $0.start, end: Double(chapterIndex * 10) + $0.end)
            },
            timingPrecision: range == nil ? nil : .exactSynthesisWord)
    }

    private func diagnostic(
        chapterIndex: Int = 1
    ) -> PronunciationAuditDiagnostic {
        PronunciationAuditDiagnostic(
            reason: .spokenSurfaceMismatch,
            blockID: "s\(chapterIndex)-b0",
            chunkIndex: 0,
            chapterIndex: chapterIndex,
            expectedDisplayText: "verified filesystem",
            reconstructedSpokenSurface: "verified file system",
            fallbackHits: [])
    }

    @Test func manifestPreservesStableEvidenceAndCountsEveryWatchedWord() {
        let second = decision(word: "filesystem", ruleID: "override.builtin.filesystem", chapterIndex: 2)
        let first = decision(word: "verified", ruleID: "g2p.lexicon.verified", chapterIndex: 0)
        let manifest = PronunciationAuditManifest.make(
            renderVersion: 11,
            voice: VoiceID("af_heart"),
            captureCoverage: .complete,
            legacyChapterIndexes: [],
            audiobookURL: URL(fileURLWithPath: "/private/books/question-machine.m4b"),
            reelURL: URL(fileURLWithPath: "/private/books/question-machine.pronunciation-reel.m4b"),
            audiobookSHA256: String(repeating: "a", count: 64),
            listeningReelSHA256: String(repeating: "b", count: 64),
            watchWords: ["verified", "startable", "filesystem"],
            decisions: [first, second],
            diagnostics: [])

        #expect(manifest.schemaVersion == 2)
        #expect(manifest.renderVersion == 11)
        #expect(manifest.voice == "af_heart")
        #expect(manifest.coverage == .complete)
        #expect(manifest.legacyChapterIndexes.isEmpty)
        #expect(manifest.audiobookFileName == "question-machine.m4b")
        #expect(manifest.audiobookSHA256 == String(repeating: "a", count: 64))
        #expect(manifest.listeningReelFileName == "question-machine.pronunciation-reel.m4b")
        #expect(manifest.listeningReelSHA256 == String(repeating: "b", count: 64))
        #expect(manifest.watchCounts == ["filesystem": 1, "startable": 0, "verified": 1])
        #expect(manifest.decisions == [first, second])
        #expect(manifest.decisions[0].chapterRelativeAudioRange == .init(start: 1, end: 1.4))
        #expect(manifest.decisions[0].bookRelativeAudioRange == .init(start: 1, end: 1.4))
        #expect(manifest.decisions[0].kokoroTokenIDs == [11, 22, 33])
        #expect(manifest.diagnostics.isEmpty)
    }

    @Test func manifestDistinguishesLegacyCaptureFromEvidenceDiagnostics() {
        let evidenceDiagnostic = diagnostic()
        let incompleteEvidence = PronunciationAuditManifest.make(
            renderVersion: 11,
            voice: VoiceID("af_heart"),
            captureCoverage: .complete,
            legacyChapterIndexes: [],
            audiobookURL: URL(fileURLWithPath: "/tmp/book.m4b"),
            reelURL: nil,
            audiobookSHA256: String(repeating: "a", count: 64),
            listeningReelSHA256: nil,
            watchWords: ["verified"],
            decisions: [],
            diagnostics: [evidenceDiagnostic])
        let legacy = PronunciationAuditManifest.make(
            renderVersion: 11,
            voice: VoiceID("af_heart"),
            captureCoverage: .incompleteLegacyCapture,
            legacyChapterIndexes: [1, 7],
            audiobookURL: URL(fileURLWithPath: "/tmp/book.m4b"),
            reelURL: nil,
            audiobookSHA256: String(repeating: "a", count: 64),
            listeningReelSHA256: nil,
            watchWords: ["verified"],
            decisions: [],
            diagnostics: [evidenceDiagnostic])

        #expect(incompleteEvidence.coverage == .incompleteEvidence)
        #expect(incompleteEvidence.diagnostics == [evidenceDiagnostic])
        #expect(legacy.coverage == .incompleteLegacyCapture)
        #expect(legacy.legacyChapterIndexes == [1, 7])
    }

    @Test func legacyChapterListWinsOverOtherwiseCompleteOrDiagnosticCoverage() {
        let manifest = PronunciationAuditManifest.make(
            renderVersion: 11,
            voice: VoiceID("af_heart"),
            captureCoverage: .incompleteEvidence,
            legacyChapterIndexes: [9, 2, 9],
            audiobookURL: URL(fileURLWithPath: "/tmp/book.m4b"),
            reelURL: nil,
            audiobookSHA256: String(repeating: "a", count: 64),
            listeningReelSHA256: nil,
            watchWords: ["verified"],
            decisions: [],
            diagnostics: [diagnostic()])

        #expect(manifest.coverage == .incompleteLegacyCapture)
        #expect(manifest.legacyChapterIndexes == [2, 9])
    }

    @Test func zeroDecisionManifestStillCarriesAllZeroWatchCountsAndNoReel() {
        let manifest = PronunciationAuditManifest.make(
            renderVersion: 11,
            voice: VoiceID("af_heart"),
            captureCoverage: .complete,
            legacyChapterIndexes: [],
            audiobookURL: URL(fileURLWithPath: "/tmp/book.m4b"),
            reelURL: nil,
            audiobookSHA256: String(repeating: "a", count: 64),
            listeningReelSHA256: nil,
            watchWords: ["verified", "filesystem", "verified"],
            decisions: [],
            diagnostics: [])

        #expect(manifest.decisions.isEmpty)
        #expect(manifest.watchCounts == ["filesystem": 0, "verified": 0])
        #expect(manifest.listeningReelFileName == nil)
        #expect(manifest.coverage == .complete)
    }

    @Test func manifestEncodingIsPrettySortedAndAtomicallyReplacesExistingFile() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let destination = tmp.appendingPathComponent("book.pronunciation-audit.json")

        let oldManifest = PronunciationAuditManifest.make(
            renderVersion: 10,
            voice: VoiceID("old_voice"),
            captureCoverage: .complete,
            legacyChapterIndexes: [],
            audiobookURL: tmp.appendingPathComponent("book.m4b"),
            reelURL: nil,
            audiobookSHA256: String(repeating: "c", count: 64),
            listeningReelSHA256: nil,
            watchWords: ["verified"],
            decisions: [decision(word: "verified", ruleID: "old", chapterIndex: 0)],
            diagnostics: [])
        let newManifest = PronunciationAuditManifest.make(
            renderVersion: 11,
            voice: VoiceID("af_heart"),
            captureCoverage: .complete,
            legacyChapterIndexes: [],
            audiobookURL: tmp.appendingPathComponent("book.m4b"),
            reelURL: nil,
            audiobookSHA256: String(repeating: "d", count: 64),
            listeningReelSHA256: nil,
            watchWords: ["verified", "filesystem"],
            decisions: [],
            diagnostics: [])

        try oldManifest.write(to: destination)
        try newManifest.write(to: destination)

        let data = try Data(contentsOf: destination)
        let text = try #require(String(data: data, encoding: .utf8))
        let decoded = try JSONDecoder().decode(PronunciationAuditManifest.self, from: data)
        let audiobookKey = try #require(text.range(of: "\"audiobookFileName\""))
        let coverageKey = try #require(text.range(of: "\"coverage\""))
        let schemaKey = try #require(text.range(of: "\"schemaVersion\""))
        let siblings = try FileManager.default.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: nil)

        #expect(text.hasPrefix("{\n"))
        #expect(audiobookKey.lowerBound < coverageKey.lowerBound)
        #expect(coverageKey.lowerBound < schemaKey.lowerBound)
        #expect(decoded == newManifest)
        #expect(siblings.map(\.lastPathComponent) == [destination.lastPathComponent])
        #expect(!text.contains(tmp.path))
    }

    @Test func manifestEncodingRejectsMalformedOrUnpairedArtifactHashes() {
        let malformed = PronunciationAuditManifest.make(
            renderVersion: NarrationFileNaming.renderVersion,
            voice: VoiceID("af_heart"),
            captureCoverage: .complete,
            legacyChapterIndexes: [],
            audiobookURL: URL(fileURLWithPath: "/tmp/book.m4b"),
            reelURL: nil,
            audiobookSHA256: "NOT-A-SHA256",
            listeningReelSHA256: nil,
            watchWords: [],
            decisions: [],
            diagnostics: [])
        let unpaired = PronunciationAuditManifest.make(
            renderVersion: NarrationFileNaming.renderVersion,
            voice: VoiceID("af_heart"),
            captureCoverage: .complete,
            legacyChapterIndexes: [],
            audiobookURL: URL(fileURLWithPath: "/tmp/book.m4b"),
            reelURL: URL(fileURLWithPath: "/tmp/book.pronunciation-reel.m4b"),
            audiobookSHA256: String(repeating: "a", count: 64),
            listeningReelSHA256: nil,
            watchWords: [],
            decisions: [],
            diagnostics: [])

        #expect(throws: Error.self) { _ = try malformed.encoded() }
        #expect(throws: Error.self) { _ = try unpaired.encoded() }
    }
}
