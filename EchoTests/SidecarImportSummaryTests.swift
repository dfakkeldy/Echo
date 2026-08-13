// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
struct SidecarImportSummaryTests {

    // MARK: - readAlongStatusLine

    @Test func appliedSummaryReadsAsWordLevel() {
        let summary = SidecarImportSummary(
            status: .applied, sidecarFound: true, blocksMatched: 741, wordsWritten: 9000,
            totalBlocks: 755, updatedAt: "2026-07-18T00:00:00Z")
        #expect(summary.readAlongStatusLine == "Word-level (sidecar, 741/755 blocks)")
    }

    @Test func unresolvedSummaryReadsAsParagraphLevelWithReason() {
        let summary = SidecarImportSummary(
            status: .foundButUnresolved, sidecarFound: true, blocksMatched: 0, wordsWritten: 0,
            totalBlocks: 755, updatedAt: "2026-07-18T00:00:00Z")
        #expect(
            summary.readAlongStatusLine == "Paragraph-level — alignment file found but not applied")
    }

    @Test func notDownloadedSummaryNamesTheICloudReason() {
        let summary = SidecarImportSummary(
            status: .notDownloaded, sidecarFound: true, blocksMatched: 0, wordsWritten: 0,
            totalBlocks: 755, updatedAt: "2026-07-18T00:00:00Z")
        #expect(
            summary.readAlongStatusLine
                == "Paragraph-level — alignment file not downloaded from iCloud")
    }

    @Test func noSidecarSummaryReadsAsParagraphLevel() {
        let summary = SidecarImportSummary(
            status: .noSidecar, sidecarFound: false, blocksMatched: 0, wordsWritten: 0,
            totalBlocks: 12, updatedAt: "2026-07-18T00:00:00Z")
        #expect(summary.readAlongStatusLine == "Paragraph-level (no word timings)")
    }

    // MARK: - Persistence round-trip

    @Test func summaryRoundTripsThroughBookPreferences() throws {
        let store = try #require(UserDefaults(suiteName: "sidecar-summary-\(UUID().uuidString)"))
        let audiobookID = "book-42"
        let summary = SidecarImportSummary(
            status: .applied, sidecarFound: true, blocksMatched: 5, wordsWritten: 20,
            totalBlocks: 6, updatedAt: "2026-07-18T12:00:00Z")

        BookPreferencesService.saveSidecarSummary(summary, for: audiobookID, store: store)
        #expect(
            BookPreferencesService.loadSidecarSummary(for: audiobookID, store: store) == summary)

        BookPreferencesService.saveSidecarSummary(nil, for: audiobookID, store: store)
        #expect(BookPreferencesService.loadSidecarSummary(for: audiobookID, store: store) == nil)
    }

    // MARK: - ReadAlongStatusResolver fallback (no persisted summary)

    @Test func resolverPrefersPersistedSummary() throws {
        let store = try #require(UserDefaults(suiteName: "sidecar-resolver-\(UUID().uuidString)"))
        let db = try DatabaseService(inMemory: ())
        let audiobookID = "bk"
        BookPreferencesService.saveSidecarSummary(
            SidecarImportSummary(
                status: .applied, sidecarFound: true, blocksMatched: 3, wordsWritten: 10,
                totalBlocks: 4, updatedAt: "2026-07-18T00:00:00Z"),
            for: audiobookID, store: store)

        let line = ReadAlongStatusResolver.statusLine(
            audiobookID: audiobookID, writer: db.writer, store: store)
        #expect(line == "Word-level (sidecar, 3/4 blocks)")
    }

    @Test func resolverFallsBackToLiveWordRowsWhenNoSummary() throws {
        let store = try #require(UserDefaults(suiteName: "sidecar-resolver-\(UUID().uuidString)"))
        let db = try DatabaseService(inMemory: ())
        try seedBook(db)

        // No summary + no rows → paragraph-level.
        #expect(
            ReadAlongStatusResolver.statusLine(audiobookID: "bk", writer: db.writer, store: store)
                == "Paragraph-level (no word timings)")

        // No summary + rows present → word-level (source unknown).
        try WordTimingDAO(db: db.writer).insert([
            WordTimingRecord(
                audiobookID: "bk", epubBlockID: "b0", wordIndex: 0, word: "one",
                audioStartTime: 0, audioEndTime: 0.5, confidence: 0.5, source: "interpolated")
        ])
        #expect(
            ReadAlongStatusResolver.statusLine(audiobookID: "bk", writer: db.writer, store: store)
                == "Word-level (aligned)")
    }

    // MARK: - applySidecarWords per-block reporting (fix 5)

    @Test func applySidecarWordsReportsMismatchesAndCounts() throws {
        let db = try DatabaseService(inMemory: ())
        try seedBook(db)
        let dao = WordTimingDAO(db: db.writer)
        // b0 has 3 tokenized rows; b1 has 2.
        try dao.insert([
            interpolatedRow("b0", index: 0, word: "one"),
            interpolatedRow("b0", index: 1, word: "two"),
            interpolatedRow("b0", index: 2, word: "three"),
            interpolatedRow("b1", index: 0, word: "four"),
            interpolatedRow("b1", index: 1, word: "five"),
        ])

        let application = try WordTimingMaterializer.applySidecarWords(
            audiobookID: "bk",
            sidecarWordsByBlock: [
                // Mismatch: 2 sidecar words for a 3-row block → skipped.
                "b0": [word("one", 0, 0.4), word("two", 0.4, 0.9)],
                // Match: applied.
                "b1": [word("four", 20, 20.5), word("five", 20.5, 21)],
                // No rows for this block → recorded separately.
                "ghost": [word("boo", 0, 1)],
            ],
            writer: db.writer)

        #expect(application.blocksApplied == 1)
        #expect(application.wordsApplied == 2)
        #expect(application.blocksWithoutRows == 1)
        #expect(application.mismatches.count == 1)
        let mismatch = try #require(application.mismatches.first)
        #expect(mismatch.blockID == "b0")
        #expect(mismatch.blockRows == 3)
        #expect(mismatch.sidecarWords == 2)

        // b0 kept its interpolated rows; b1 took sidecar rows.
        #expect(
            try dao.words(forAudiobook: "bk", blockID: "b0").allSatisfy {
                $0.source == "interpolated"
            })
        #expect(
            try dao.words(forAudiobook: "bk", blockID: "b1").allSatisfy { $0.source == "sidecar" })
    }

    // MARK: - Helpers

    private func seedBook(_ db: DatabaseService) throws {
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('bk','Book',100.0)")
            try db.execute(
                sql: """
                    INSERT INTO epub_block
                      (id, audiobook_id, spine_href, spine_index, block_index,
                       sequence_index, block_kind, text, is_hidden)
                    VALUES ('b0','bk','c.xhtml',0,0,0,'paragraph','one two three', 0),
                           ('b1','bk','c.xhtml',0,1,1,'paragraph','four five', 0)
                    """)
        }
    }

    private func interpolatedRow(_ blockID: String, index: Int, word: String) -> WordTimingRecord {
        WordTimingRecord(
            audiobookID: "bk", epubBlockID: blockID, wordIndex: index, word: word,
            audioStartTime: Double(index), audioEndTime: Double(index) + 0.5, confidence: 0.5,
            source: "interpolated")
    }

    private func word(_ text: String, _ start: TimeInterval, _ end: TimeInterval)
        -> AlignmentSidecar.Anchor.Word
    {
        AlignmentSidecar.Anchor.Word(word: text, start: start, end: end)
    }
}
