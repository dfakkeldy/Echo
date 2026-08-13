// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import ZIPFoundation

nonisolated enum GeneratedAnthologyReconcileFaultPoint: Sendable {
    case afterUpserts
    case afterObsoleteDeletion
    case afterTOCReplacement
}

nonisolated enum EPUBBlockPersistencePolicy: Sendable {
    case replaceAll
    case reconcileGenerated
}

/// Exact, bounded database state captured immediately before a trusted
/// generated import. It never captures notes, bookmarks, or non-EPUB timeline
/// rows because reconcile does not mutate those user-owned tables.
nonisolated struct GeneratedAnthologyImportRollbackSnapshot: Sendable {
    struct Limits: Sendable {
        let maximumBlocks: Int
        let maximumTOCEntries: Int
        let maximumAnchors: Int
        let maximumWordTimings: Int
        let maximumTimelineItems: Int
        let maximumTotalRows: Int
        let maximumEncodedBytes: Int

        init(
            maximumBlocks: Int = 200_000,
            maximumTOCEntries: Int = 50_000,
            maximumAnchors: Int = 200_000,
            maximumWordTimings: Int = 500_000,
            maximumTimelineItems: Int = 250_000,
            maximumTotalRows: Int = 750_000,
            maximumEncodedBytes: Int = 32 * 1_024 * 1_024
        ) {
            self.maximumBlocks = maximumBlocks
            self.maximumTOCEntries = maximumTOCEntries
            self.maximumAnchors = maximumAnchors
            self.maximumWordTimings = maximumWordTimings
            self.maximumTimelineItems = maximumTimelineItems
            self.maximumTotalRows = maximumTotalRows
            self.maximumEncodedBytes = maximumEncodedBytes
        }

        static let production = Self()
    }

    private let audiobookID: String
    private let priorBlockIDs: Set<String>
    private let blocks: [EPubBlockRecord]
    private let tocEntries: [EPubTOCEntryRecord]
    private let anchors: [AlignmentAnchorRecord]
    private let wordTimings: [WordTimingRecord]
    private let timelineItems: [TimelineItem]

    static func capture(
        audiobookID: String,
        candidateBlockIDs: Set<String> = [],
        limits: Limits = .production,
        in database: Database
    ) throws -> Self {
        guard audiobookID.isEmpty == false,
            limits.maximumBlocks >= 0,
            limits.maximumTOCEntries >= 0,
            limits.maximumAnchors >= 0,
            limits.maximumWordTimings >= 0,
            limits.maximumTimelineItems >= 0,
            limits.maximumTotalRows >= 0,
            limits.maximumEncodedBytes >= 0
        else {
            throw GeneratedAnthologyImportError.invalidRollbackSnapshot
        }
        var encodedBytes = 0
        var priorBlockIDs = Set<String>()
        var blocks: [EPubBlockRecord] = []
        let blockRequest =
            EPubBlockRecord
            .filter(Column("audiobook_id") == audiobookID)
        let blockCursor = try blockRequest.fetchCursor(database)
        while let block = try blockCursor.next() {
            guard priorBlockIDs.count < limits.maximumBlocks else {
                throw GeneratedAnthologyImportError.rollbackSnapshotLimitExceeded
            }
            try charge(
                block.id.utf8.count,
                usedBytes: &encodedBytes,
                limit: limits.maximumEncodedBytes)
            priorBlockIDs.insert(block.id)
            if candidateBlockIDs.contains(block.id)
                || isReconciledBlock(block, audiobookID: audiobookID)
            {
                try append(
                    block,
                    to: &blocks,
                    maximumCount: limits.maximumBlocks,
                    usedBytes: &encodedBytes,
                    maximumEncodedBytes: limits.maximumEncodedBytes)
            }
        }
        let blockIDs = Set(blocks.map(\.id))

        let tocEntries: [EPubTOCEntryRecord] = try fetchBounded(
            EPubTOCEntryRecord
                .filter(Column("audiobook_id") == audiobookID),
            maximumCount: limits.maximumTOCEntries,
            usedBytes: &encodedBytes,
            maximumEncodedBytes: limits.maximumEncodedBytes,
            in: database)
        let anchors: [AlignmentAnchorRecord] = try fetchBounded(
            AlignmentAnchorRecord
                .filter(Column("audiobook_id") == audiobookID),
            maximumCount: limits.maximumAnchors,
            usedBytes: &encodedBytes,
            maximumEncodedBytes: limits.maximumEncodedBytes,
            including: { blockIDs.contains($0.epubBlockID) },
            in: database)
        let wordTimings: [WordTimingRecord] = try fetchBounded(
            WordTimingRecord
                .filter(Column("audiobook_id") == audiobookID),
            maximumCount: limits.maximumWordTimings,
            usedBytes: &encodedBytes,
            maximumEncodedBytes: limits.maximumEncodedBytes,
            including: { blockIDs.contains($0.epubBlockID) },
            in: database)
        let timelineItems: [TimelineItem] = try fetchBounded(
            TimelineItem
                .filter(Column("audiobook_id") == audiobookID)
                .filter(Column("source_table") == EPubBlockRecord.databaseTableName),
            maximumCount: limits.maximumTimelineItems,
            usedBytes: &encodedBytes,
            maximumEncodedBytes: limits.maximumEncodedBytes,
            including: {
                $0.epubBlockID.map(blockIDs.contains) == true
            },
            in: database)
        let counts = [
            blocks.count,
            tocEntries.count,
            anchors.count,
            wordTimings.count,
            timelineItems.count,
        ]
        guard counts.reduce(0, +) <= limits.maximumTotalRows
        else {
            throw GeneratedAnthologyImportError.rollbackSnapshotLimitExceeded
        }
        let snapshot = Self(
            audiobookID: audiobookID,
            priorBlockIDs: priorBlockIDs,
            blocks: blocks,
            tocEntries: tocEntries,
            anchors: anchors,
            wordTimings: wordTimings,
            timelineItems: timelineItems)
        try snapshot.validate(
            requestedAudiobookID: audiobookID,
            in: database)
        return snapshot
    }

    func restore(
        audiobookID requestedAudiobookID: String,
        in database: Database
    ) throws {
        try validate(
            requestedAudiobookID: requestedAudiobookID,
            in: database)

        let snapshotBlockIDs = Set(blocks.map(\.id))
        let currentBlocks =
            try EPubBlockRecord
            .filter(Column("audiobook_id") == requestedAudiobookID)
            .fetchAll(database)
        let affectedBlockIDs =
            snapshotBlockIDs.union(
                currentBlocks.compactMap {
                    Self.isReconciledBlock(
                        $0,
                        audiobookID: requestedAudiobookID)
                        ? $0.id : nil
                })
        for blockID in affectedBlockIDs {
            try AlignmentAnchorRecord
                .filter(Column("audiobook_id") == requestedAudiobookID)
                .filter(Column("epub_block_id") == blockID)
                .deleteAll(database)
            try WordTimingRecord
                .filter(Column("audiobook_id") == requestedAudiobookID)
                .filter(Column("epub_block_id") == blockID)
                .deleteAll(database)
            try TimelineItem
                .filter(Column("audiobook_id") == requestedAudiobookID)
                .filter(Column("source_table") == EPubBlockRecord.databaseTableName)
                .filter(Column("epub_block_id") == blockID)
                .deleteAll(database)
        }
        try EPubTOCEntryRecord
            .filter(Column("audiobook_id") == requestedAudiobookID)
            .deleteAll(database)

        for current in currentBlocks where snapshotBlockIDs.contains(current.id) == false {
            guard
                Self.isReconciledBlock(
                    current,
                    audiobookID: requestedAudiobookID)
            else {
                continue
            }
            _ =
                try EPubBlockRecord
                .filter(Column("audiobook_id") == requestedAudiobookID)
                .filter(Column("id") == current.id)
                .deleteAll(database)
        }
        for var block in blocks {
            try block.save(database)
        }
        for var entry in tocEntries {
            try entry.insert(database)
        }
        for var anchor in anchors {
            try anchor.insert(database)
        }
        for var timing in wordTimings {
            try timing.insert(database)
        }
        for var item in timelineItems {
            try item.insert(database)
        }
    }

    private func validate(
        requestedAudiobookID: String,
        in database: Database
    ) throws {
        guard requestedAudiobookID == audiobookID,
            blocks.allSatisfy({ $0.audiobookID == audiobookID }),
            tocEntries.allSatisfy({ $0.audiobookID == audiobookID }),
            anchors.allSatisfy({ $0.audiobookID == audiobookID }),
            wordTimings.allSatisfy({ $0.audiobookID == audiobookID }),
            timelineItems.allSatisfy({
                $0.audiobookID == audiobookID
                    && $0.sourceTable == EPubBlockRecord.databaseTableName
            }),
            Self.unique(blocks.map(\.id)),
            Self.unique(tocEntries.map(\.id)),
            Self.unique(anchors.map(\.id)),
            Self.unique(timelineItems.map(\.id))
        else {
            throw GeneratedAnthologyImportError.invalidRollbackSnapshot
        }

        let blockIDs = priorBlockIDs
        let tocIDs = Set(tocEntries.map(\.id))
        guard
            tocEntries.allSatisfy({
                ($0.parentID == nil || tocIDs.contains($0.parentID!))
                    && ($0.blockID == nil || blockIDs.contains($0.blockID!))
            }),
            anchors.allSatisfy({ blockIDs.contains($0.epubBlockID) }),
            wordTimings.allSatisfy({ blockIDs.contains($0.epubBlockID) }),
            timelineItems.allSatisfy({
                $0.epubBlockID.map(blockIDs.contains) == true
            })
        else {
            throw GeneratedAnthologyImportError.invalidRollbackSnapshot
        }

        guard
            try Self.hasNoCrossBookCollision(
                EPubBlockRecord.self,
                ids: blocks.map(\.id),
                audiobookID: audiobookID,
                database: database),
            try Self.hasNoCrossBookCollision(
                EPubTOCEntryRecord.self,
                ids: tocEntries.map(\.id),
                audiobookID: audiobookID,
                database: database),
            try Self.hasNoCrossBookCollision(
                AlignmentAnchorRecord.self,
                ids: anchors.map(\.id),
                audiobookID: audiobookID,
                database: database),
            try Self.hasNoCrossBookCollision(
                TimelineItem.self,
                ids: timelineItems.map(\.id),
                audiobookID: audiobookID,
                database: database)
        else {
            throw GeneratedAnthologyImportError.crossBookCollision
        }
        let timingIDs = wordTimings.compactMap(\.id)
        if timingIDs.isEmpty == false {
            let collision =
                try WordTimingRecord
                .filter(timingIDs.contains(Column("id")))
                .filter(Column("audiobook_id") != audiobookID)
                .fetchCount(database)
            guard collision == 0 else {
                throw GeneratedAnthologyImportError.crossBookCollision
            }
        }
    }

    private static func unique<Value: Hashable>(_ values: [Value]) -> Bool {
        Set(values).count == values.count
    }

    private static func isReconciledBlock(
        _ block: EPubBlockRecord,
        audiobookID: String
    ) -> Bool {
        block.sourceChapterKey != nil
            || block.id.hasPrefix("epub-\(audiobookID)-generic-")
    }

    private static func append<Record: Encodable>(
        _ record: Record,
        to records: inout [Record],
        maximumCount: Int,
        usedBytes: inout Int,
        maximumEncodedBytes: Int
    ) throws {
        guard records.count < maximumCount else {
            throw GeneratedAnthologyImportError.rollbackSnapshotLimitExceeded
        }
        let encodedSize = try JSONEncoder().encode(record).count
        try charge(
            encodedSize,
            usedBytes: &usedBytes,
            limit: maximumEncodedBytes)
        records.append(record)
    }

    private static func fetchBounded<Record: FetchableRecord & Encodable>(
        _ request: QueryInterfaceRequest<Record>,
        maximumCount: Int,
        usedBytes: inout Int,
        maximumEncodedBytes: Int,
        including: (Record) -> Bool = { _ in true },
        in database: Database
    ) throws -> [Record] {
        var records: [Record] = []
        let cursor = try request.fetchCursor(database)
        while let record = try cursor.next() {
            guard including(record) else { continue }
            try append(
                record,
                to: &records,
                maximumCount: maximumCount,
                usedBytes: &usedBytes,
                maximumEncodedBytes: maximumEncodedBytes)
        }
        return records
    }

    private static func charge(
        _ byteCount: Int,
        usedBytes: inout Int,
        limit: Int
    ) throws {
        guard byteCount >= 0,
            usedBytes <= limit,
            byteCount <= limit - usedBytes
        else {
            throw GeneratedAnthologyImportError.rollbackSnapshotLimitExceeded
        }
        usedBytes += byteCount
    }

    private static func hasNoCrossBookCollision<Record: FetchableRecord & TableRecord>(
        _ type: Record.Type,
        ids: [String],
        audiobookID: String,
        database: Database
    ) throws -> Bool {
        guard ids.isEmpty == false else { return true }
        return try Record
            .filter(ids.contains(Column("id")))
            .filter(Column("audiobook_id") != audiobookID)
            .fetchCount(database) == 0
    }
}

nonisolated enum GeneratedAnthologyImportReconciler {
    static func importArchive(
        at epubURL: URL,
        audiobookID: String,
        identity: GeneratedAnthologyImportIdentity,
        databaseService: DatabaseService,
        rollbackLimits: GeneratedAnthologyImportRollbackSnapshot.Limits = .production
    ) async throws -> AnthologyLibraryImportReceipt {
        let extractionRoot = FileManager.default.temporaryDirectory
            .appending(
                path: "echo-generated-anthology-\(UUID().uuidString)",
                directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: extractionRoot,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: extractionRoot) }

        let archive = try Archive(url: epubURL, accessMode: .read)
        var totalExtracted: UInt64 = 0
        for entry in archive {
            guard entry.type == .file else { continue }
            totalExtracted = try ArchiveExtractionLimits.checkedTotal(
                addingEntryOfSize: entry.uncompressedSize,
                to: totalExtracted)
            let destination = try safeDestination(
                for: entry.path,
                within: extractionRoot)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            _ = try archive.extract(entry, to: destination)
        }

        let parsed = try await MainActor.run {
            try parseEPUBBlocks(
                audiobookID: audiobookID,
                epubURL: extractionRoot,
                generatedIdentity: identity)
        }
        let candidateBlockIDs = Set(parsed.blocks.map(\.id))
        guard candidateBlockIDs.count == parsed.blocks.count else {
            throw GeneratedAnthologyImportError.duplicateStableBlock
        }
        let rollbackSnapshot = try await databaseService.writer.read { database in
            try GeneratedAnthologyImportRollbackSnapshot.capture(
                audiobookID: audiobookID,
                candidateBlockIDs: candidateBlockIDs,
                limits: rollbackLimits,
                in: database)
        }

        let importer = await EPUBImportService(
            assetStorage: EPUBAssetStorage(databaseService: databaseService))
        _ = try await importer.import(
            audiobookID: audiobookID,
            epubURL: extractionRoot,
            chapters: [],
            bookDuration: nil,
            generatedIdentity: identity,
            persistencePolicy: .reconcileGenerated)
        return AnthologyLibraryImportReceipt(
            audiobookID: audiobookID,
            generatedRollbackSnapshot: rollbackSnapshot)
    }

    static func reconcile(
        audiobookID: String,
        incomingBlocks: [EPubBlockRecord],
        tocEntries: [EPubTOCEntryRecord],
        faultInjector:
            (@Sendable (GeneratedAnthologyReconcileFaultPoint) throws -> Void)? = nil,
        in database: Database
    ) throws {
        let incomingByID = try validatedIncoming(
            audiobookID: audiobookID,
            blocks: incomingBlocks,
            database: database)
        let existing =
            try EPubBlockRecord
            .filter(Column("audiobook_id") == audiobookID)
            .fetchAll(database)
        let existingByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })

        for incoming in incomingBlocks {
            var merged = incoming
            if let prior = existingByID[incoming.id] {
                let sourceUnchanged =
                    prior.blockKind == incoming.blockKind
                    && prior.text == incoming.text
                    && prior.sourceChapterKey == incoming.sourceChapterKey
                merged.cardColor = prior.cardColor
                merged.chapterThemeColor = prior.chapterThemeColor
                merged.isHidden = prior.isHidden
                merged.hiddenReason = prior.hiddenReason
                merged.createdAt = prior.createdAt ?? incoming.createdAt
                merged.modifiedAt = prior.modifiedAt
                if !sourceUnchanged {
                    try deleteDerivedRows(
                        audiobookID: audiobookID,
                        blockID: incoming.id,
                        in: database)
                }
                try merged.update(database)
            } else {
                try merged.insert(database)
            }
        }
        try faultInjector?(.afterUpserts)

        let obsoleteIDs = existing.compactMap { block -> String? in
            guard incomingByID[block.id] == nil,
                block.sourceChapterKey != nil
                    || block.id.hasPrefix("epub-\(audiobookID)-generic-")
            else {
                return nil
            }
            return block.id
        }
        for blockID in obsoleteIDs {
            try deleteDerivedRows(
                audiobookID: audiobookID,
                blockID: blockID,
                in: database)
            _ =
                try EPubBlockRecord
                .filter(Column("audiobook_id") == audiobookID)
                .filter(Column("id") == blockID)
                .deleteAll(database)
        }
        try faultInjector?(.afterObsoleteDeletion)

        try EPubTOCEntryRecord
            .filter(Column("audiobook_id") == audiobookID)
            .deleteAll(database)
        for var entry in tocEntries {
            guard entry.audiobookID == audiobookID else {
                throw GeneratedAnthologyImportError.invalidStableBlock
            }
            try entry.insert(database)
        }
        try faultInjector?(.afterTOCReplacement)
    }

    private static func validatedIncoming(
        audiobookID: String,
        blocks: [EPubBlockRecord],
        database: Database
    ) throws -> [String: EPubBlockRecord] {
        guard audiobookID.isEmpty == false, blocks.isEmpty == false else {
            throw GeneratedAnthologyImportError.incompleteStableBlockSet
        }
        var byID: [String: EPubBlockRecord] = [:]
        var hasGeneratedChapter = false
        for block in blocks {
            guard block.audiobookID == audiobookID,
                byID.updateValue(block, forKey: block.id) == nil
            else {
                throw GeneratedAnthologyImportError.duplicateStableBlock
            }
            if block.sourceChapterKey != nil {
                hasGeneratedChapter = true
                guard block.id.hasPrefix("epub-\(audiobookID)-s"),
                    block.blockIndex >= 0
                else {
                    throw GeneratedAnthologyImportError.invalidStableBlock
                }
            } else {
                guard block.id.hasPrefix("epub-\(audiobookID)-generic-") else {
                    throw GeneratedAnthologyImportError.invalidStableBlock
                }
            }
        }
        guard hasGeneratedChapter else {
            throw GeneratedAnthologyImportError.incompleteStableBlockSet
        }

        let collisions =
            try EPubBlockRecord
            .filter(blocks.map(\.id).contains(Column("id")))
            .fetchAll(database)
            .filter { $0.audiobookID != audiobookID }
        guard collisions.isEmpty else {
            throw GeneratedAnthologyImportError.crossBookCollision
        }
        return byID
    }

    private static func deleteDerivedRows(
        audiobookID: String,
        blockID: String,
        in database: Database
    ) throws {
        try AlignmentAnchorRecord
            .filter(Column("audiobook_id") == audiobookID)
            .filter(Column("epub_block_id") == blockID)
            .deleteAll(database)
        try WordTimingRecord
            .filter(Column("audiobook_id") == audiobookID)
            .filter(Column("epub_block_id") == blockID)
            .deleteAll(database)
        try TimelineItem
            .filter(Column("audiobook_id") == audiobookID)
            .filter(Column("source_table") == EPubBlockRecord.databaseTableName)
            .filter(Column("epub_block_id") == blockID)
            .deleteAll(database)
    }

    private static func safeDestination(
        for entryPath: String,
        within root: URL
    ) throws -> URL {
        guard entryPath.isEmpty == false,
            entryPath.hasPrefix("/") == false,
            entryPath.contains("\\") == false
        else {
            throw GeneratedAnthologyImportError.invalidStableBlock
        }
        let destination = root.appending(path: entryPath).standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        guard destination.path.hasPrefix(rootPath + "/") else {
            throw GeneratedAnthologyImportError.invalidStableBlock
        }
        return destination
    }
}
