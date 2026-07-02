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
        sequenceIndex: Int
    ) -> EPubBlockRecord {
        EPubBlockRecord(
            id: id,
            audiobookID: audiobookID,
            spineHref: "chapter.xhtml",
            spineIndex: 0,
            blockIndex: sequenceIndex,
            sequenceIndex: sequenceIndex,
            blockKind: "paragraph",
            text: "Block \(sequenceIndex)",
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
