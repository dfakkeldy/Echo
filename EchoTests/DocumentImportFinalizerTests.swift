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

        let firstFinalized =
            await DocumentImportFinalizer
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

        let secondFinalized =
            await DocumentImportFinalizer
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

        let finalized =
            await DocumentImportFinalizer
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
        #expect(
            words.map(\.word) == ["First", "stale", "paragraph", "Second", "stale", "paragraph"])
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

    @Test func identityBearingCodeCueWordsImportAsSidecarRows() async throws {
        let audiobookID = "code-book"
        let databaseService = try DatabaseService(inMemory: ())
        let code = block(
            id: "epub-\(audiobookID)-s0-b0",
            audiobookID: audiobookID,
            sequenceIndex: 0,
            text: "let value = answer + 42",
            kind: .code,
            narrationText: "Example value assignment."
        )
        let blocks = [code]
        try insertAudiobook(audiobookID, databaseService: databaseService)
        try EPubBlockDAO(db: databaseService.writer).insertAll(blocks)

        let fileURL = try makeDocumentURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let sidecar = [
            AlignmentSidecar.Anchor(
                blockId: "s0-b0",
                timestamp: 1,
                confidence: 1,
                words: [
                    .init(word: "Example", start: 1, end: 1.3),
                    .init(word: "value", start: 1.3, end: 1.6),
                    .init(word: "assignment", start: 1.6, end: 2),
                ],
                sourceBlockIdentity: AlignmentSidecar.sourceIdentity(for: code)
            )
        ]
        try AlignmentSidecar.encode(sidecar).write(to: AlignmentSidecar.url(forEPUB: fileURL))

        let finalized = await DocumentImportFinalizer.finalize(
            audiobookID: audiobookID,
            blocks: blocks,
            fileURL: fileURL,
            duration: 10,
            databaseService: databaseService
        )

        #expect(finalized)
        let rows = try WordTimingDAO(db: databaseService.writer)
            .words(forAudiobook: audiobookID, blockID: code.id)
        #expect(rows.map(\.word) == ["Example", "value", "assignment."])
        #expect(rows.allSatisfy { $0.source == "sidecar" })
    }

    @Test func mismatchedSourceIdentityPreservesExistingMachineAlignment() async throws {
        let audiobookID = "identity-book"
        let databaseService = try DatabaseService(inMemory: ())
        let blocks = [
            block(
                id: "epub-\(audiobookID)-s0-b0",
                audiobookID: audiobookID,
                sequenceIndex: 0,
                text: "Current source paragraph"
            )
        ]
        try insertAudiobook(audiobookID, databaseService: databaseService)
        try EPubBlockDAO(db: databaseService.writer).insertAll(blocks)
        try AlignmentAnchorDAO(db: databaseService.writer).insert(
            anchor(
                id: "existing-machine",
                audiobookID: audiobookID,
                blockID: blocks[0].id,
                source: .autoAlignment,
                audioTime: 7
            )
        )
        defer {
            UserDefaults.standard.removeObject(
                forKey: BookPreferencesService.sidecarSummaryKey(for: audiobookID)
            )
        }

        let fileURL = try makeDocumentURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let sidecar = [
            AlignmentSidecar.Anchor(
                blockId: "s0-b0",
                timestamp: 40,
                confidence: 1,
                sourceBlockIdentity: "identity-from-a-different-source"
            )
        ]
        try AlignmentSidecar.encode(sidecar).write(to: AlignmentSidecar.url(forEPUB: fileURL))

        #expect(
            await DocumentImportFinalizer.finalize(
                audiobookID: audiobookID,
                blocks: blocks,
                fileURL: fileURL,
                duration: 100,
                databaseService: databaseService
            )
        )
        let anchors = try AlignmentAnchorDAO(db: databaseService.writer).anchors(for: audiobookID)
        #expect(anchors.map(\.id) == ["existing-machine"])
        let summary = try #require(BookPreferencesService.loadSidecarSummary(for: audiobookID))
        #expect(summary.status == .staleSource)
        #expect(summary.readAlongStatusLine.contains("stale"))
    }

    @Test func unresolvedIdentityBearingAnchorRejectsEntireSidecar() async throws {
        let audiobookID = "partial-identity-book"
        let databaseService = try DatabaseService(inMemory: ())
        let blocks = [
            block(
                id: "epub-\(audiobookID)-s0-b0",
                audiobookID: audiobookID,
                sequenceIndex: 0,
                text: "Current source paragraph"
            ),
            block(
                id: "epub-\(audiobookID)-s0-b1",
                audiobookID: audiobookID,
                sequenceIndex: 1,
                text: "Existing aligned paragraph"
            ),
        ]
        try insertAudiobook(audiobookID, databaseService: databaseService)
        try EPubBlockDAO(db: databaseService.writer).insertAll(blocks)
        try AlignmentAnchorDAO(db: databaseService.writer).insert(
            anchor(
                id: "existing-machine",
                audiobookID: audiobookID,
                blockID: blocks[1].id,
                source: .autoAlignment,
                audioTime: 7
            )
        )
        defer {
            UserDefaults.standard.removeObject(
                forKey: BookPreferencesService.sidecarSummaryKey(for: audiobookID)
            )
        }

        let fileURL = try makeDocumentURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let sidecar = [
            AlignmentSidecar.Anchor(
                blockId: "s0-b0",
                timestamp: 10,
                confidence: 1,
                sourceBlockIdentity: AlignmentSidecar.sourceIdentity(for: blocks[0])
            ),
            AlignmentSidecar.Anchor(
                blockId: "s9-b9",
                timestamp: 20,
                confidence: 1,
                sourceBlockIdentity: "foreign-source-identity"
            ),
        ]
        try AlignmentSidecar.encode(sidecar).write(to: AlignmentSidecar.url(forEPUB: fileURL))

        #expect(
            await DocumentImportFinalizer.finalize(
                audiobookID: audiobookID,
                blocks: blocks,
                fileURL: fileURL,
                duration: 100,
                databaseService: databaseService
            )
        )
        let anchors = try AlignmentAnchorDAO(db: databaseService.writer).anchors(for: audiobookID)
        #expect(anchors.map(\.id) == ["existing-machine"])
        let summary = try #require(BookPreferencesService.loadSidecarSummary(for: audiobookID))
        #expect(summary.status == .staleSource)
    }

    @Test func legacySidecarIsRejectedWhenCodeCanShiftPortableSuffixes() async throws {
        let audiobookID = "legacy-code-book"
        let databaseService = try DatabaseService(inMemory: ())
        let blocks = [
            block(
                id: "epub-\(audiobookID)-s0-b0",
                audiobookID: audiobookID,
                sequenceIndex: 0,
                text: "Before listing"
            ),
            block(
                id: "epub-\(audiobookID)-s0-b1",
                audiobookID: audiobookID,
                sequenceIndex: 1,
                text: "let shifted = true",
                kind: .code,
                narrationText: "Code listing."
            ),
            block(
                id: "epub-\(audiobookID)-s0-b2",
                audiobookID: audiobookID,
                sequenceIndex: 2,
                text: "After listing"
            ),
        ]
        try insertAudiobook(audiobookID, databaseService: databaseService)
        try EPubBlockDAO(db: databaseService.writer).insertAll(blocks)
        try AlignmentAnchorDAO(db: databaseService.writer).insert(
            anchor(
                id: "existing-machine",
                audiobookID: audiobookID,
                blockID: blocks[2].id,
                source: .autoAlignment,
                audioTime: 60
            )
        )
        defer {
            UserDefaults.standard.removeObject(
                forKey: BookPreferencesService.sidecarSummaryKey(for: audiobookID)
            )
        }

        let fileURL = try makeDocumentURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        try Data(
            """
            [{"blockId":"s0-b1","confidence":1,"timestamp":20}]
            """.utf8
        ).write(to: AlignmentSidecar.url(forEPUB: fileURL))

        #expect(
            await DocumentImportFinalizer.finalize(
                audiobookID: audiobookID,
                blocks: blocks,
                fileURL: fileURL,
                duration: 100,
                databaseService: databaseService
            )
        )
        let anchors = try AlignmentAnchorDAO(db: databaseService.writer).anchors(for: audiobookID)
        #expect(anchors.map(\.id) == ["existing-machine"])
        #expect(!anchors.contains { $0.epubBlockID == blocks[1].id })
        let summary = try #require(BookPreferencesService.loadSidecarSummary(for: audiobookID))
        #expect(summary.status == .staleSource)
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

    /// Regression (review finding): audio-less imports (text/markdown via
    /// `TextAutoImportScanner`, audio-less EPUB/PDF via
    /// `PlayerLoadingCoordinator.importDocumentForAudiolessBook`) finalize with
    /// `duration: nil`, which triggers a trailing `recalculateTimeline()` AFTER
    /// the sidecar ingest. That recalc re-materializes (re-interpolates) word
    /// rows — sidecar words must be applied after it, or they are silently
    /// wiped back to interpolated 0.5-confidence rows.
    @Test func sidecarWordsSurviveAudiolessFinalization() async throws {
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
            duration: nil,
            databaseService: databaseService
        )

        #expect(finalized)
        let dao = WordTimingDAO(db: databaseService.writer)
        let first = try dao.words(forAudiobook: audiobookID, blockID: blocks[0].id)
        #expect(first.allSatisfy { $0.source == "sidecar" })
        #expect(first.allSatisfy { $0.confidence == 0.9 })
        #expect(first.map(\.audioStartTime) == [0.0, 0.4, 0.9])
        #expect(first.map(\.audioEndTime) == [0.4, 0.9, 1.5])
        let second = try dao.words(forAudiobook: audiobookID, blockID: blocks[1].id)
        #expect(second.allSatisfy { $0.source == "sidecar" })
        #expect(second.map(\.audioStartTime) == [20.0, 20.5])
    }

    /// The `duration: nil` variant of `repeatedFinalizationReappliesSidecarWords`:
    /// every re-finalize (each app launch) runs both the refresh recalc AND the
    /// trailing audio-less recalc — sidecar words must survive both, repeatedly.
    @Test func repeatedAudiolessFinalizationReappliesSidecarWords() async throws {
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
                duration: nil,
                databaseService: databaseService
            )
            #expect(finalized)
        }

        let dao = WordTimingDAO(db: databaseService.writer)
        let first = try dao.words(forAudiobook: audiobookID, blockID: blocks[0].id)
        #expect(first.allSatisfy { $0.source == "sidecar" })
        #expect(first.allSatisfy { $0.confidence == 0.9 })
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

    /// A found-but-unresolved sidecar (all portable ids foreign) must NOT leave
    /// read-along empty. With no prior anchors and a known duration it falls back
    /// to first/last boundary anchors so `word_timing` is materialized via
    /// interpolation, and records the degraded reason in the summary. (Before the
    /// J-Space hardening this wrote nothing at all — the silent-degradation bug.)
    @Test func allForeignWordBearingSidecarFallsBackToInterpolationFloor() async throws {
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
                text: "four five six"),
        ]
        try insertAudiobook(audiobookID, databaseService: databaseService)
        try EPubBlockDAO(db: databaseService.writer).insertAll(blocks)
        defer {
            UserDefaults.standard.removeObject(
                forKey: BookPreferencesService.sidecarSummaryKey(for: audiobookID))
        }

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
        // Interpolation floor materialized (was empty before the fix), and no
        // foreign word leaked in.
        let words = try WordTimingDAO(db: databaseService.writer).words(forAudiobook: audiobookID)
        #expect(!words.isEmpty)
        #expect(words.allSatisfy { $0.source == "interpolated" })
        #expect(!words.contains { $0.word == "ghost" })
        // First/last boundary anchors were created to span the interpolation.
        let anchorIDs = Set(
            try AlignmentAnchorDAO(db: databaseService.writer).anchors(for: audiobookID).map(\.id))
        #expect(anchorIDs.contains("anchor-init-first-\(audiobookID)"))
        #expect(anchorIDs.contains("anchor-init-last-\(audiobookID)"))
        // The observability summary records why it degraded.
        let summary = try #require(
            BookPreferencesService.loadSidecarSummary(for: audiobookID))
        #expect(summary.sidecarFound)
        #expect(summary.status == .foundButUnresolved)
        #expect(summary.blocksMatched == 0)
        #expect(summary.readAlongStatusLine.hasPrefix("Paragraph-level"))
    }

    /// A prior auto-alignment (machine anchors) must survive an unresolved
    /// sidecar reopen: the interpolation-floor fallback is anchor-aware and only
    /// creates first/last boundaries when there is no existing alignment to
    /// preserve, so good alignment is never clobbered by a crude pair.
    @Test func unresolvedSidecarPreservesExistingMachineAnchors() async throws {
        let audiobookID = "book-1"
        let databaseService = try DatabaseService(inMemory: ())
        let blocks = [
            block(
                id: "epub-\(audiobookID)-s0-b0", audiobookID: audiobookID, sequenceIndex: 0,
                text: "one two"),
            block(
                id: "epub-\(audiobookID)-s0-b1", audiobookID: audiobookID, sequenceIndex: 1,
                text: "three four"),
        ]
        try insertAudiobook(audiobookID, databaseService: databaseService)
        try EPubBlockDAO(db: databaseService.writer).insertAll(blocks)
        defer {
            UserDefaults.standard.removeObject(
                forKey: BookPreferencesService.sidecarSummaryKey(for: audiobookID))
        }
        // Seed a prior auto-alignment machine anchor.
        try AlignmentAnchorDAO(db: databaseService.writer).insert(
            anchor(
                id: "auto-anchor", audiobookID: audiobookID, blockID: blocks[1].id,
                source: .autoAlignment, audioTime: 12))

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
        let anchorIDs = Set(
            try AlignmentAnchorDAO(db: databaseService.writer).anchors(for: audiobookID).map(\.id))
        // The prior auto-align anchor survives; no crude first/last pair replaced it.
        #expect(anchorIDs.contains("auto-anchor"))
        #expect(!anchorIDs.contains("anchor-init-first-\(audiobookID)"))
        // Read-along still materialized from the preserved alignment.
        #expect(
            try WordTimingDAO(db: databaseService.writer).hasWordTimings(forAudiobook: audiobookID))
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
        defer {
            UserDefaults.standard.removeObject(
                forKey: BookPreferencesService.sidecarSummaryKey(for: audiobookID))
        }

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
        // A malformed sidecar can't be decoded, but the import must still fall
        // back to the interpolation floor rather than writing nothing.
        let anchorIDs = Set(
            try AlignmentAnchorDAO(db: databaseService.writer).anchors(for: audiobookID).map(\.id))
        #expect(anchorIDs.contains("anchor-init-first-\(audiobookID)"))
        #expect(anchorIDs.contains("anchor-init-last-\(audiobookID)"))
        #expect(
            try WordTimingDAO(db: databaseService.writer).hasWordTimings(forAudiobook: audiobookID))
        let summary = try #require(
            BookPreferencesService.loadSidecarSummary(for: audiobookID))
        #expect(summary.status == .decodeError)
    }

    /// Fix 6: a resolving sidecar records an `applied` summary with the block /
    /// word counts Book Settings surfaces.
    @Test func resolvingSidecarWritesAppliedSummary() async throws {
        let audiobookID = "book-1"
        let databaseService = try DatabaseService(inMemory: ())
        let blocks = [
            block(
                id: "epub-\(audiobookID)-s0-b0", audiobookID: audiobookID, sequenceIndex: 0,
                text: "one two three")
        ]
        try insertAudiobook(audiobookID, databaseService: databaseService)
        try EPubBlockDAO(db: databaseService.writer).insertAll(blocks)
        defer {
            UserDefaults.standard.removeObject(
                forKey: BookPreferencesService.sidecarSummaryKey(for: audiobookID))
        }

        let fileURL = try makeDocumentURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let sidecar = [
            AlignmentSidecar.Anchor(
                blockId: "s0-b0", timestamp: 0, confidence: 1,
                words: [
                    AlignmentSidecar.Anchor.Word(word: "one", start: 0.0, end: 0.4),
                    AlignmentSidecar.Anchor.Word(word: "two", start: 0.4, end: 0.9),
                    AlignmentSidecar.Anchor.Word(word: "three", start: 0.9, end: 1.5),
                ])
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
        let summary = try #require(
            BookPreferencesService.loadSidecarSummary(for: audiobookID))
        #expect(summary.status == .applied)
        #expect(summary.sidecarFound)
        #expect(summary.blocksMatched == 1)
        #expect(summary.wordsWritten == 3)
        #expect(summary.totalBlocks == 1)
        #expect(summary.readAlongStatusLine == "Word-level (sidecar, 1/1 blocks)")
    }

    /// Fix 4: a sidecar that only appears AFTER first import gets its word
    /// timings applied on a later open (not just its anchors).
    @Test func backfillOnReopenAppliesSidecarWordTimings() async throws {
        let audiobookID = "book-1"
        let databaseService = try DatabaseService(inMemory: ())
        let blocks = [
            block(
                id: "epub-\(audiobookID)-s0-b0", audiobookID: audiobookID, sequenceIndex: 0,
                text: "one two")
        ]
        try insertAudiobook(audiobookID, databaseService: databaseService)
        try EPubBlockDAO(db: databaseService.writer).insertAll(blocks)
        defer {
            UserDefaults.standard.removeObject(
                forKey: BookPreferencesService.sidecarSummaryKey(for: audiobookID))
        }

        let fileURL = try makeDocumentURL()
        defer { try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent()) }
        let sidecar = [
            AlignmentSidecar.Anchor(
                blockId: "s0-b0", timestamp: 0, confidence: 1,
                words: [
                    AlignmentSidecar.Anchor.Word(word: "one", start: 0.0, end: 0.4),
                    AlignmentSidecar.Anchor.Word(word: "two", start: 0.4, end: 0.9),
                ])
        ]
        try JSONEncoder().encode(sidecar).write(to: AlignmentSidecar.url(forEPUB: fileURL))

        // Reopen path: blocks already exist, so this loads them itself and
        // replays only the sidecar branch.
        let applied =
            await DocumentImportFinalizer
            .finalizeExistingImportIfAlignmentSidecarPresent(
                audiobookID: audiobookID,
                fileURL: fileURL,
                duration: nil,
                databaseService: databaseService
            )

        #expect(applied)
        let words = try WordTimingDAO(db: databaseService.writer)
            .words(forAudiobook: audiobookID, blockID: blocks[0].id)
        #expect(words.map(\.word) == ["one", "two"])
        #expect(words.allSatisfy { $0.source == "sidecar" })
    }

    /// Fix 2: sidecar discovery keyed off an m4b URL resolves both an exact
    /// `<m4b-base>.alignment.json` and any `*.alignment.json` sibling, so an
    /// audiobook whose alignment file sits next to the audio still resolves.
    @Test func alignmentSidecarURLResolvesM4bKeyedSidecar() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "m4b-sidecar-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let m4bURL = directory.appending(path: "MyBook.m4b")
        try Data().write(to: m4bURL)

        // Exact m4b-base match.
        let exact = directory.appending(path: "MyBook.alignment.json")
        try Data("[]".utf8).write(to: exact)
        #expect(
            DocumentImportFinalizer.alignmentSidecarURL(for: m4bURL)?.lastPathComponent
                == "MyBook.alignment.json")

        // Sibling fallback: a differently-named *.alignment.json still resolves.
        try FileManager.default.removeItem(at: exact)
        let sibling = directory.appending(path: "MyBook-audio.alignment.json")
        try Data("[]".utf8).write(to: sibling)
        #expect(
            DocumentImportFinalizer.alignmentSidecarURL(for: m4bURL)?.lastPathComponent
                == "MyBook-audio.alignment.json")
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
        text: String? = nil,
        kind: EPubBlockRecord.Kind = .paragraph,
        narrationText: String? = nil
    ) -> EPubBlockRecord {
        var block = EPubBlockRecord(
            id: id,
            audiobookID: audiobookID,
            spineHref: "chapter.xhtml",
            spineIndex: 0,
            blockIndex: sequenceIndex,
            sequenceIndex: sequenceIndex,
            blockKind: kind.rawValue,
            text: text ?? "Block \(sequenceIndex)",
            chapterIndex: 0,
            isHidden: false
        )
        block.narrationText = narrationText
        return block
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
