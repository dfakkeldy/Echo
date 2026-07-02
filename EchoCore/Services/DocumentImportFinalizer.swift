// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import os.log

/// The shared post-import tail for document (EPUB / text) ingestion: create
/// initial alignment anchors (alignment.json sidecar → CloudKit → first/last
/// fallback), recalculate the read-along timeline, and post
/// `timelineItemsIngested`. Extracted from `EPUBAutoImportScanner` so EPUB and
/// text import share one copy (no divergence in anchor/timeline behavior).
enum DocumentImportFinalizer {
    private static let logger = Logger(category: "DocumentImportFinalizer")
    private static let humanAnchorSources: Set<String> = [
        AlignmentAnchorRecord.Source.moveToNow.rawValue,
        AlignmentAnchorRecord.Source.searchResult.rawValue,
        AlignmentAnchorRecord.Source.chapterBoundary.rawValue,
    ]

    static func finalize(
        audiobookID: String,
        blocks: [EPubBlockRecord],
        fileURL: URL,
        duration: TimeInterval?,
        databaseService: DatabaseService
    ) async -> Bool {
        // Create initial system anchors (first block → 0, last block → duration)
        // so every block gets an interpolated timestamp from the start.
        let alignmentService = AlignmentService(
            db: databaseService.writer, audiobookID: audiobookID)

        if let alignmentSidecarURL = alignmentSidecarURL(for: fileURL) {
            do {
                let data = try Data(contentsOf: alignmentSidecarURL)
                let exports = try AlignmentSidecar.decode(data)
                logger.info("Found alignment.json sidecar with \(exports.count) anchors.")
                // Sidecar block ids are the portable `s<i>-b<j>` suffix. Re-prefix
                // each with THIS device's audiobookID and drop any whose block isn't
                // present locally (stale/foreign sidecar) so we never insert orphan
                // anchors. Resolve FIRST so an all-foreign sidecar is a true no-op
                // that leaves existing anchors intact.
                let localBlockIDs = Set(blocks.map(\.id))
                let createdAt = AlignmentService.isoFormatter.string(from: Date())
                let resolved: [AlignmentAnchorRecord] = exports.compactMap { export in
                    let blockID = AlignmentSidecar.localBlockID(
                        export.blockId, audiobookID: audiobookID)
                    guard localBlockIDs.contains(blockID) else { return nil }
                    return AlignmentAnchorRecord(
                        id: UUID().uuidString,
                        audiobookID: audiobookID,
                        epubBlockID: blockID,
                        audioTime: export.timestamp,
                        audioEndTime: nil,
                        anchorKind: AlignmentAnchorRecord.AnchorKind.point.rawValue,
                        source: AlignmentAnchorRecord.Source.autoAlignment.rawValue,
                        note: "Mac App DTW alignment",
                        createdAt: createdAt,
                        modifiedAt: nil
                    )
                }
                if resolved.isEmpty {
                    logger.info(
                        "alignment.json: 0 of \(exports.count) anchors resolved to local blocks — leaving existing anchors intact"
                    )
                } else {
                    do {
                        try replaceMachineAnchors(
                            with: resolved,
                            audiobookID: audiobookID,
                            writer: databaseService.writer,
                            alignmentService: alignmentService
                        )
                        logger.info(
                            "Ingested \(resolved.count)/\(exports.count) anchors from alignment.json (\(exports.count - resolved.count) dropped: block not present locally; user anchors preserved)"
                        )
                    } catch {
                        logger.error(
                            "Failed to persist alignment.json anchors: \(error.localizedDescription)"
                        )
                        return false
                    }
                }
            } catch {
                logger.error(
                    "Failed to ingest alignment.json sidecar: \(error.localizedDescription)")
            }
        } else if let duration {
            var downloadedAnchors: [AlignmentAnchorRecord] = []
            let folderURL = fileURL.deletingLastPathComponent()
            let record = try? AudiobookDAO(db: databaseService.writer).get(audiobookID)
            let (title, author) = EPUBAutoImportScanner.anchorLookupMetadata(
                folderURL: folderURL, record: record)

            if CloudKitSyncService.canAccessConfiguredContainer() {
                let syncService = CloudKitSyncService(db: databaseService.writer)
                do {
                    downloadedAnchors = try await syncService.downloadAnchors(
                        audiobookID: audiobookID,
                        title: title,
                        author: author,
                        duration: duration
                    )
                } catch {
                    logger.error(
                        "CloudKit anchor lookup failed; falling back to local anchors: \(error.localizedDescription)"
                    )
                }
            } else {
                logger.info(
                    "Skipped CloudKit anchor lookup because the app is not entitled for the configured CloudKit container."
                )
            }

            if !downloadedAnchors.isEmpty {
                do {
                    try replaceMachineAnchors(
                        with: downloadedAnchors,
                        audiobookID: audiobookID,
                        writer: databaseService.writer,
                        alignmentService: alignmentService
                    )
                    logger.info("Ingested \(downloadedAnchors.count) anchors from CloudKit")
                } catch {
                    logger.error(
                        "Failed to ingest CloudKit anchors: \(error.localizedDescription)")
                    return false
                }
            } else if let firstBlock = blocks.first, let lastBlock = blocks.last {
                // Anchor first block to time 0
                let firstAnchor = AlignmentAnchorRecord(
                    id: "anchor-init-first-\(audiobookID)",
                    audiobookID: audiobookID,
                    epubBlockID: firstBlock.id,
                    audioTime: 0,
                    audioEndTime: nil,
                    anchorKind: AlignmentAnchorRecord.AnchorKind.point.rawValue,
                    source: AlignmentAnchorRecord.Source.imported.rawValue,
                    note: "Auto-created: first block",
                    createdAt: AlignmentService.isoFormatter.string(from: Date()),
                    modifiedAt: nil
                )
                // Anchor last block to total duration
                let lastAnchor = AlignmentAnchorRecord(
                    id: "anchor-init-last-\(audiobookID)",
                    audiobookID: audiobookID,
                    epubBlockID: lastBlock.id,
                    audioTime: duration,
                    audioEndTime: nil,
                    anchorKind: AlignmentAnchorRecord.AnchorKind.point.rawValue,
                    source: AlignmentAnchorRecord.Source.imported.rawValue,
                    note: "Auto-created: last block",
                    createdAt: AlignmentService.isoFormatter.string(from: Date()),
                    modifiedAt: nil
                )
                do {
                    try replaceMachineAnchors(
                        with: [firstAnchor, lastAnchor],
                        audiobookID: audiobookID,
                        writer: databaseService.writer,
                        alignmentService: alignmentService
                    )
                    logger.info("Created initial alignment anchors for \(audiobookID)")
                } catch {
                    logger.error(
                        "Failed to create initial alignment anchors for \(audiobookID): \(error.localizedDescription)"
                    )
                    return false
                }
            }
        } else {
            logger.info("Skipped CloudKit anchor lookup for audio-less document \(audiobookID)")
        }

        // Always recalculate timeline to ensure chapter-boundary virtual
        // anchors cover blocks even when total duration is unknown.
        if duration == nil {
            do {
                try alignmentService.recalculateTimeline()
                logger.info("Recalculated EPUB timeline (no book duration) for \(audiobookID)")
            } catch {
                logger.error(
                    "Failed to recalculate EPUB timeline for \(audiobookID): \(error.localizedDescription)"
                )
                return false
            }
        }

        // Post notification to trigger UI refresh.
        await MainActor.run {
            NotificationCenter.default.post(
                name: .timelineItemsIngested,
                object: nil,
                userInfo: ["audiobookID": audiobookID]
            )
        }
        return true
    }

    private static func replaceMachineAnchors(
        with anchors: [AlignmentAnchorRecord],
        audiobookID: String,
        writer: DatabaseWriter,
        alignmentService: AlignmentService
    ) throws {
        try writer.write { db in
            try AlignmentAnchorRecord
                .filter(Column("audiobook_id") == audiobookID)
                .filter(!humanAnchorSources.contains(Column("source")))
                .deleteAll(db)

            for anchor in anchors {
                var mutable = anchor
                try mutable.upsert(db)
            }
        }
        try alignmentService.recalculateTimeline()
    }

    /// Replays only the alignment-sidecar branch for documents whose text blocks
    /// already exist. This lets a later-arriving or corrected `.alignment.json`
    /// light up read-along without forcing a destructive document re-import.
    @discardableResult
    static func finalizeExistingImportIfAlignmentSidecarPresent(
        audiobookID: String,
        fileURL: URL,
        duration: TimeInterval?,
        databaseService: DatabaseService
    ) async -> Bool {
        guard alignmentSidecarURL(for: fileURL) != nil else { return false }

        let blocks: [EPubBlockRecord]
        do {
            blocks = try EPubBlockDAO(db: databaseService.writer).allBlocks(for: audiobookID)
        } catch {
            logger.error(
                "Failed to load existing document blocks for sidecar finalization: \(error.localizedDescription)"
            )
            return false
        }

        guard !blocks.isEmpty else { return false }
        return await finalize(
            audiobookID: audiobookID,
            blocks: blocks,
            fileURL: fileURL,
            duration: duration,
            databaseService: databaseService
        )
    }

    static func alignmentSidecarURL(
        for fileURL: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        let exactURL = AlignmentSidecar.url(forEPUB: fileURL)
        if fileManager.fileExists(atPath: exactURL.path) { return exactURL }

        let directory = fileURL.deletingLastPathComponent()
        guard
            let siblings = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles])
        else { return nil }

        let exactName = exactURL.lastPathComponent
        let sidecars = siblings
            .filter { $0.lastPathComponent.localizedCaseInsensitiveCompare(exactName) == .orderedSame }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        if let match = sidecars.first { return match }

        return siblings
            .filter { $0.lastPathComponent.lowercased().hasSuffix(".alignment.json") }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .first
    }
}
