// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
struct DocumentImportFinalizerTests {
    @Test func fallbackAnchorsPreserveHumanAnchorsAndReplaceMachineAnchors() async throws {
        let audiobookID = "book-1"
        let databaseService = try DatabaseService(inMemory: ())
        let blocks = [
            block(id: "book-1-s0-b0", audiobookID: audiobookID, sequenceIndex: 0),
            block(id: "book-1-s0-b1", audiobookID: audiobookID, sequenceIndex: 1),
        ]
        try insertAudiobook(audiobookID, databaseService: databaseService)
        try EPubBlockDAO(db: databaseService.writer).insertAll(blocks)

        let anchorDAO = AlignmentAnchorDAO(db: databaseService.writer)
        try anchorDAO.insert(
            anchor(
                id: "human-anchor",
                audiobookID: audiobookID,
                blockID: blocks[0].id,
                source: .moveToNow,
                audioTime: 25
            )
        )
        try anchorDAO.insert(
            anchor(
                id: "machine-anchor",
                audiobookID: audiobookID,
                blockID: blocks[1].id,
                source: .autoAlignment,
                audioTime: 50
            )
        )

        let fileURL = try makeDocumentURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let finalized = await DocumentImportFinalizer.finalize(
            audiobookID: audiobookID,
            blocks: blocks,
            fileURL: fileURL,
            duration: 100,
            databaseService: databaseService
        )

        #expect(finalized)
        let anchorIDs = Set(try anchorDAO.anchors(for: audiobookID).map(\.id))
        #expect(anchorIDs.contains("human-anchor"))
        #expect(!anchorIDs.contains("machine-anchor"))
        #expect(anchorIDs.contains("anchor-init-first-\(audiobookID)"))
        #expect(anchorIDs.contains("anchor-init-last-\(audiobookID)"))
    }

    @Test func fallbackFinalizationReportsPersistenceFailure() async throws {
        let audiobookID = "book-1"
        let databaseService = try DatabaseService(inMemory: ())
        let blocks = [
            block(id: "missing-block-1", audiobookID: audiobookID, sequenceIndex: 0),
            block(id: "missing-block-2", audiobookID: audiobookID, sequenceIndex: 1),
        ]
        try insertAudiobook(audiobookID, databaseService: databaseService)

        let fileURL = try makeDocumentURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }

        let finalized = await DocumentImportFinalizer.finalize(
            audiobookID: audiobookID,
            blocks: blocks,
            fileURL: fileURL,
            duration: 100,
            databaseService: databaseService
        )

        #expect(finalized == false)
    }

    @Test func sidecarAnchorsPreserveHumanAnchorsAndReplaceMachineAnchors() async throws {
        let audiobookID = "book-1"
        let databaseService = try DatabaseService(inMemory: ())
        let blocks = [
            block(id: "epub-\(audiobookID)-s0-b0", audiobookID: audiobookID, sequenceIndex: 0),
            block(id: "epub-\(audiobookID)-s0-b1", audiobookID: audiobookID, sequenceIndex: 1),
        ]
        try insertAudiobook(audiobookID, databaseService: databaseService)
        try EPubBlockDAO(db: databaseService.writer).insertAll(blocks)

        let anchorDAO = AlignmentAnchorDAO(db: databaseService.writer)
        try anchorDAO.insert(
            anchor(
                id: "human-anchor",
                audiobookID: audiobookID,
                blockID: blocks[0].id,
                source: .chapterBoundary,
                audioTime: 25
            )
        )
        try anchorDAO.insert(
            anchor(
                id: "machine-anchor",
                audiobookID: audiobookID,
                blockID: blocks[1].id,
                source: .continuousBackground,
                audioTime: 50
            )
        )

        let fileURL = try makeDocumentURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let sidecar = [
            AlignmentSidecar.Anchor(blockId: "s0-b1", timestamp: 75, confidence: 1)
        ]
        try JSONEncoder().encode(sidecar).write(to: AlignmentSidecar.url(forEPUB: fileURL))

        let finalized = await DocumentImportFinalizer.finalize(
            audiobookID: audiobookID,
            blocks: blocks,
            fileURL: fileURL,
            duration: 100,
            databaseService: databaseService
        )

        #expect(finalized)
        let anchors = try anchorDAO.anchors(for: audiobookID)
        let anchorIDs = Set(anchors.map(\.id))
        #expect(anchorIDs.contains("human-anchor"))
        #expect(!anchorIDs.contains("machine-anchor"))

        let sidecarAnchor = try #require(
            anchors.first {
                $0.epubBlockID == blocks[1].id
                    && $0.source == AlignmentAnchorRecord.Source.autoAlignment.rawValue
            }
        )
        #expect(abs(sidecarAnchor.audioTime - 75) < 0.001)
        #expect(anchors.count == 2)
    }

    @Test func repeatedExistingSidecarFinalizationDoesNotRewriteAnchors() async throws {
        let audiobookID = "book-1"
        let databaseService = try DatabaseService(inMemory: ())
        let blocks = [
            block(id: "epub-\(audiobookID)-s0-b0", audiobookID: audiobookID, sequenceIndex: 0),
            block(id: "epub-\(audiobookID)-s0-b1", audiobookID: audiobookID, sequenceIndex: 1),
        ]
        try insertAudiobook(audiobookID, databaseService: databaseService)
        try EPubBlockDAO(db: databaseService.writer).insertAll(blocks)

        let fileURL = try makeDocumentURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let sidecar = [
            AlignmentSidecar.Anchor(blockId: "s0-b0", timestamp: 12.5, confidence: 1),
            AlignmentSidecar.Anchor(blockId: "s0-b1", timestamp: 75, confidence: 1),
        ]
        try JSONEncoder().encode(sidecar).write(to: AlignmentSidecar.url(forEPUB: fileURL))

        let firstFinalized = await DocumentImportFinalizer
            .finalizeExistingImportIfAlignmentSidecarPresent(
                audiobookID: audiobookID,
                fileURL: fileURL,
                duration: 100,
                databaseService: databaseService
            )

        let anchorDAO = AlignmentAnchorDAO(db: databaseService.writer)
        let firstAnchorIDs = try anchorDAO.anchors(for: audiobookID)
            .sorted { $0.epubBlockID < $1.epubBlockID }
            .map(\.id)

        let secondFinalized = await DocumentImportFinalizer
            .finalizeExistingImportIfAlignmentSidecarPresent(
                audiobookID: audiobookID,
                fileURL: fileURL,
                duration: 100,
                databaseService: databaseService
            )

        let secondAnchorIDs = try anchorDAO.anchors(for: audiobookID)
            .sorted { $0.epubBlockID < $1.epubBlockID }
            .map(\.id)

        #expect(firstFinalized)
        #expect(secondFinalized)
        #expect(
            secondAnchorIDs == firstAnchorIDs,
            "Unchanged sidecars should not rewrite existing anchors on every app launch."
        )
    }

    @Test func existingMatchingSidecarRefreshesTimelineAndWordTimings() async throws {
        let audiobookID = "book-1"
        let databaseService = try DatabaseService(inMemory: ())
        let blocks = [
            block(
                id: "epub-\(audiobookID)-s0-b0",
                audiobookID: audiobookID,
                sequenceIndex: 0,
                text: "First stale paragraph"),
            block(
                id: "epub-\(audiobookID)-s0-b1",
                audiobookID: audiobookID,
                sequenceIndex: 1,
                text: "Second stale paragraph"),
        ]
        try insertAudiobook(audiobookID, databaseService: databaseService)
        try EPubBlockDAO(db: databaseService.writer).insertAll(blocks)

        let anchorDAO = AlignmentAnchorDAO(db: databaseService.writer)
        try anchorDAO.insert(
            anchor(
                id: "already-ingested-0",
                audiobookID: audiobookID,
                blockID: blocks[0].id,
                source: .autoAlignment,
                audioTime: 0
            )
        )
        try anchorDAO.insert(
            anchor(
                id: "already-ingested-1",
                audiobookID: audiobookID,
                blockID: blocks[1].id,
                source: .autoAlignment,
                audioTime: 20
            )
        )

        let fileURL = try makeDocumentURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let sidecar = [
            AlignmentSidecar.Anchor(blockId: "s0-b0", timestamp: 0, confidence: 1),
            AlignmentSidecar.Anchor(blockId: "s0-b1", timestamp: 20, confidence: 1),
        ]
        try JSONEncoder().encode(sidecar).write(to: AlignmentSidecar.url(forEPUB: fileURL))

        let finalized = await DocumentImportFinalizer
            .finalizeExistingImportIfAlignmentSidecarPresent(
                audiobookID: audiobookID,
                fileURL: fileURL,
                duration: 40,
                databaseService: databaseService
            )

        #expect(finalized)
        let timelineItems = try TimelineDAO(db: databaseService.writer).items(for: audiobookID)
        #expect(timelineItems.count == 2)
        let words = try WordTimingDAO(db: databaseService.writer).words(forAudiobook: audiobookID)
        #expect(words.map(\.word) == ["First", "stale", "paragraph", "Second", "stale", "paragraph"])
    }

    @Test func sidecarWordsBecomeSidecarSourcedWordTimingRows() async throws {
        let audiobookID = "book-1"
        let databaseService = try DatabaseService(inMemory: ())
        let blocks = [
            block(
                id: "epub-\(audiobookID)-s0-b0",
                audiobookID: audiobookID,
                sequenceIndex: 0,
                text: "one two three"),
            block(
                id: "epub-\(audiobookID)-s0-b1",
                audiobookID: audiobookID,
                sequenceIndex: 1,
                text: "four five"),
        ]
        try insertAudiobook(audiobookID, databaseService: databaseService)
        try EPubBlockDAO(db: databaseService.writer).insertAll(blocks)

        let fileURL = try makeDocumentURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let sidecar = [
            AlignmentSidecar.Anchor(
                blockId: "s0-b0", timestamp: 0, confidence: 1,
                words: [
                    AlignmentSidecar.Anchor.Word(word: "one", start: 0.0, end: 0.4),
                    AlignmentSidecar.Anchor.Word(word: "two", start: 0.4, end: 0.9),
                    AlignmentSidecar.Anchor.Word(word: "three", start: 0.9, end: 1.5),
                ]),
            AlignmentSidecar.Anchor(
                blockId: "s0-b1", timestamp: 20, confidence: 1,
                words: [
                    AlignmentSidecar.Anchor.Word(word: "four", start: 20.0, end: 20.5),
                    AlignmentSidecar.Anchor.Word(word: "five", start: 20.5, end: 21.2),
                ]),
        ]
        try JSONEncoder().encode(sidecar).write(to: AlignmentSidecar.url(forEPUB: fileURL))

        let finalized = await DocumentImportFinalizer.finalize(
            audiobookID: audiobookID,
            blocks: blocks,
            fileURL: fileURL,
            duration: 40,
            databaseService: databaseService
        )

        #expect(finalized)
        let dao = WordTimingDAO(db: databaseService.writer)
        let first = try dao.words(forAudiobook: audiobookID, blockID: blocks[0].id)
        #expect(first.map(\.word) == ["one", "two", "three"])
        #expect(first.allSatisfy { $0.source == "sidecar" })
        #expect(first.map(\.audioStartTime) == [0.0, 0.4, 0.9])
        #expect(first.map(\.audioEndTime) == [0.4, 0.9, 1.5])
        // Known-true synthesis-time timing: same confidence as `synthesis` rows,
        // above interpolated (0.5) and DTW (0.85).
        #expect(first.allSatisfy { $0.confidence == 0.9 })
        let second = try dao.words(forAudiobook: audiobookID, blockID: blocks[1].id)
        #expect(second.allSatisfy { $0.source == "sidecar" })
        #expect(second.map(\.audioStartTime) == [20.0, 20.5])
    }

    /// Re-running finalize with an unchanged word-bearing sidecar (the
    /// every-app-launch refresh path) must re-apply sidecar words after the
    /// timeline/word rebuild, not leave the rebuilt interpolated rows behind.
    @Test func repeatedFinalizationReappliesSidecarWords() async throws {
        let audiobookID = "book-1"
        let databaseService = try DatabaseService(inMemory: ())
        let blocks = [
            block(
                id: "epub-\(audiobookID)-s0-b0",
                audiobookID: audiobookID,
                sequenceIndex: 0,
                text: "one two three"),
            block(
                id: "epub-\(audiobookID)-s0-b1",
                audiobookID: audiobookID,
                sequenceIndex: 1,
                text: "four five"),
        ]
        try insertAudiobook(audiobookID, databaseService: databaseService)
        try EPubBlockDAO(db: databaseService.writer).insertAll(blocks)

        let fileURL = try makeDocumentURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let sidecar = [
            AlignmentSidecar.Anchor(
                blockId: "s0-b0", timestamp: 0, confidence: 1,
                words: [
                    AlignmentSidecar.Anchor.Word(word: "one", start: 0.0, end: 0.4),
                    AlignmentSidecar.Anchor.Word(word: "two", start: 0.4, end: 0.9),
                    AlignmentSidecar.Anchor.Word(word: "three", start: 0.9, end: 1.5),
                ]),
            AlignmentSidecar.Anchor(blockId: "s0-b1", timestamp: 20, confidence: 1),
        ]
        try JSONEncoder().encode(sidecar).write(to: AlignmentSidecar.url(forEPUB: fileURL))

        for _ in 0..<2 {
            let finalized = await DocumentImportFinalizer.finalize(
                audiobookID: audiobookID,
                blocks: blocks,
                fileURL: fileURL,
                duration: 40,
                databaseService: databaseService
            )
            #expect(finalized)
        }

        let dao = WordTimingDAO(db: databaseService.writer)
        let first = try dao.words(forAudiobook: audiobookID, blockID: blocks[0].id)
        #expect(first.allSatisfy { $0.source == "sidecar" })
        #expect(first.map(\.audioStartTime) == [0.0, 0.4, 0.9])
        // The word-less anchor's block keeps its interpolated rows.
        let second = try dao.words(forAudiobook: audiobookID, blockID: blocks[1].id)
        #expect(second.allSatisfy { $0.source == "interpolated" })
    }

    @Test func foreignBlockSidecarWordsAreDropped() async throws {
        let audiobookID = "book-1"
        let databaseService = try DatabaseService(inMemory: ())
        let blocks = [
            block(
                id: "epub-\(audiobookID)-s0-b0",
                audiobookID: audiobookID,
                sequenceIndex: 0,
                text: "one two three")
        ]
        try insertAudiobook(audiobookID, databaseService: databaseService)
        try EPubBlockDAO(db: databaseService.writer).insertAll(blocks)

        let fileURL = try makeDocumentURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let sidecar = [
            AlignmentSidecar.Anchor(
                blockId: "s0-b0", timestamp: 0, confidence: 1,
                words: [
                    AlignmentSidecar.Anchor.Word(word: "one", start: 0.0, end: 0.4),
                    AlignmentSidecar.Anchor.Word(word: "two", start: 0.4, end: 0.9),
                    AlignmentSidecar.Anchor.Word(word: "three", start: 0.9, end: 1.5),
                ]),
            AlignmentSidecar.Anchor(
                blockId: "s9-b9", timestamp: 5, confidence: 1,
                words: [AlignmentSidecar.Anchor.Word(word: "ghost", start: 5.0, end: 5.5)]),
        ]
        try JSONEncoder().encode(sidecar).write(to: AlignmentSidecar.url(forEPUB: fileURL))

        let finalized = await DocumentImportFinalizer.finalize(
            audiobookID: audiobookID,
            blocks: blocks,
            fileURL: fileURL,
            duration: 40,
            databaseService: databaseService
        )

        #expect(finalized)
        let words = try WordTimingDAO(db: databaseService.writer).words(forAudiobook: audiobookID)
        #expect(words.map(\.word) == ["one", "two", "three"])
        #expect(!words.contains { $0.word == "ghost" })
    }

    /// An all-foreign word-bearing sidecar must remain a true no-op: no anchors
    /// ingested, no word rows written.
    @Test func allForeignWordBearingSidecarIsANoOp() async throws {
        let audiobookID = "book-1"
        let databaseService = try DatabaseService(inMemory: ())
        let blocks = [
            block(
                id: "epub-\(audiobookID)-s0-b0",
                audiobookID: audiobookID,
                sequenceIndex: 0,
                text: "one two three")
        ]
        try insertAudiobook(audiobookID, databaseService: databaseService)
        try EPubBlockDAO(db: databaseService.writer).insertAll(blocks)

        let fileURL = try makeDocumentURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let sidecar = [
            AlignmentSidecar.Anchor(
                blockId: "s9-b9", timestamp: 5, confidence: 1,
                words: [AlignmentSidecar.Anchor.Word(word: "ghost", start: 5.0, end: 5.5)])
        ]
        try JSONEncoder().encode(sidecar).write(to: AlignmentSidecar.url(forEPUB: fileURL))

        let finalized = await DocumentImportFinalizer.finalize(
            audiobookID: audiobookID,
            blocks: blocks,
            fileURL: fileURL,
            duration: 40,
            databaseService: databaseService
        )

        #expect(finalized)
        #expect(
            try AlignmentAnchorDAO(db: databaseService.writer).anchors(for: audiobookID).isEmpty)
        #expect(
            try WordTimingDAO(db: databaseService.writer).words(forAudiobook: audiobookID).isEmpty)
    }

    /// A word count that disagrees with the block's tokenized text means the
    /// word list can't be trusted (array order == wordIndex would drift), so
    /// that block keeps its interpolated rows — and the import still succeeds.
    @Test func wordCountMismatchSkipsThatBlocksSidecarWords() async throws {
        let audiobookID = "book-1"
        let databaseService = try DatabaseService(inMemory: ())
        let blocks = [
            block(
                id: "epub-\(audiobookID)-s0-b0",
                audiobookID: audiobookID,
                sequenceIndex: 0,
                text: "one two three"),
            block(
                id: "epub-\(audiobookID)-s0-b1",
                audiobookID: audiobookID,
                sequenceIndex: 1,
                text: "four five"),
        ]
        try insertAudiobook(audiobookID, databaseService: databaseService)
        try EPubBlockDAO(db: databaseService.writer).insertAll(blocks)

        let fileURL = try makeDocumentURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let sidecar = [
            AlignmentSidecar.Anchor(
                blockId: "s0-b0", timestamp: 0, confidence: 1,
                words: [
                    // 2 words for a 3-word block — untrustworthy, must be skipped.
                    AlignmentSidecar.Anchor.Word(word: "one", start: 0.0, end: 0.4),
                    AlignmentSidecar.Anchor.Word(word: "two", start: 0.4, end: 0.9),
                ]),
            AlignmentSidecar.Anchor(
                blockId: "s0-b1", timestamp: 20, confidence: 1,
                words: [
                    AlignmentSidecar.Anchor.Word(word: "four", start: 20.0, end: 20.5),
                    AlignmentSidecar.Anchor.Word(word: "five", start: 20.5, end: 21.2),
                ]),
        ]
        try JSONEncoder().encode(sidecar).write(to: AlignmentSidecar.url(forEPUB: fileURL))

        let finalized = await DocumentImportFinalizer.finalize(
            audiobookID: audiobookID,
            blocks: blocks,
            fileURL: fileURL,
            duration: 40,
            databaseService: databaseService
        )

        #expect(finalized)
        let dao = WordTimingDAO(db: databaseService.writer)
        let first = try dao.words(forAudiobook: audiobookID, blockID: blocks[0].id)
        #expect(first.count == 3)
        #expect(first.allSatisfy { $0.source == "interpolated" })
        let second = try dao.words(forAudiobook: audiobookID, blockID: blocks[1].id)
        #expect(second.allSatisfy { $0.source == "sidecar" })
    }

    /// A legacy anchors-only sidecar behaves exactly as before this feature:
    /// anchors ingest, word rows stay interpolated.
    @Test func legacySidecarWithoutWordsKeepsInterpolatedRows() async throws {
        let audiobookID = "book-1"
        let databaseService = try DatabaseService(inMemory: ())
        let blocks = [
            block(
                id: "epub-\(audiobookID)-s0-b0",
                audiobookID: audiobookID,
                sequenceIndex: 0,
                text: "one two three"),
            block(
                id: "epub-\(audiobookID)-s0-b1",
                audiobookID: audiobookID,
                sequenceIndex: 1,
                text: "four five"),
        ]
        try insertAudiobook(audiobookID, databaseService: databaseService)
        try EPubBlockDAO(db: databaseService.writer).insertAll(blocks)

        let fileURL = try makeDocumentURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        try Data(
            """
            [{"blockId":"s0-b0","confidence":1,"timestamp":0},
             {"blockId":"s0-b1","confidence":1,"timestamp":20}]
            """.utf8
        ).write(to: AlignmentSidecar.url(forEPUB: fileURL))

        let finalized = await DocumentImportFinalizer.finalize(
            audiobookID: audiobookID,
            blocks: blocks,
            fileURL: fileURL,
            duration: 40,
            databaseService: databaseService
        )

        #expect(finalized)
        let words = try WordTimingDAO(db: databaseService.writer).words(forAudiobook: audiobookID)
        #expect(!words.isEmpty)
        #expect(words.allSatisfy { $0.source == "interpolated" })
    }

    @Test func malformedSidecarDoesNotFailDocumentFinalization() async throws {
        let audiobookID = "book-1"
        let databaseService = try DatabaseService(inMemory: ())
        let blocks = [
            block(id: "epub-\(audiobookID)-s0-b0", audiobookID: audiobookID, sequenceIndex: 0),
            block(id: "epub-\(audiobookID)-s0-b1", audiobookID: audiobookID, sequenceIndex: 1),
        ]
        try insertAudiobook(audiobookID, databaseService: databaseService)
        try EPubBlockDAO(db: databaseService.writer).insertAll(blocks)

        let fileURL = try makeDocumentURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        try Data("{".utf8).write(to: AlignmentSidecar.url(forEPUB: fileURL))

        let finalized = await DocumentImportFinalizer.finalize(
            audiobookID: audiobookID,
            blocks: blocks,
            fileURL: fileURL,
            duration: 100,
            databaseService: databaseService
        )

        #expect(finalized)
        #expect(try AlignmentAnchorDAO(db: databaseService.writer).anchors(for: audiobookID).isEmpty)
    }

    private func insertAudiobook(
        _ audiobookID: String,
        databaseService: DatabaseService
    ) throws {
        try databaseService.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES (?, 'Test', 100)",
                arguments: [audiobookID]
            )
        }
    }

    private func block(
        id: String,
        audiobookID: String,
        sequenceIndex: Int,
        text: String? = nil
    ) -> EPubBlockRecord {
        EPubBlockRecord(
            id: id,
            audiobookID: audiobookID,
            spineHref: "chapter.xhtml",
            spineIndex: 0,
            blockIndex: sequenceIndex,
            sequenceIndex: sequenceIndex,
            blockKind: "paragraph",
            text: text ?? "Block \(sequenceIndex)",
            chapterIndex: 0,
            isHidden: false
        )
    }

    private func anchor(
        id: String,
        audiobookID: String,
        blockID: String,
        source: AlignmentAnchorRecord.Source,
        audioTime: TimeInterval
    ) -> AlignmentAnchorRecord {
        AlignmentAnchorRecord(
            id: id,
            audiobookID: audiobookID,
            epubBlockID: blockID,
            audioTime: audioTime,
            audioEndTime: nil,
            anchorKind: AlignmentAnchorRecord.AnchorKind.point.rawValue,
            source: source.rawValue,
            note: nil,
            createdAt: nil,
            modifiedAt: nil
        )
    }

    private func makeDocumentURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(
                path: "DocumentImportFinalizerTests-\(UUID().uuidString)",
                directoryHint: .isDirectory
            )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appending(path: "fixture.epub")
        try Data().write(to: fileURL)
        return fileURL
    }
}
