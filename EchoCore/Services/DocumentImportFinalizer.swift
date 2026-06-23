// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import os.log

/// The shared post-import tail for document (EPUB / text) ingestion: create
/// initial alignment anchors (alignment.json sidecar → CloudKit → first/last
/// fallback), recalculate the read-along timeline, and post
/// `timelineItemsIngested`. Extracted from `EPUBAutoImportScanner` so EPUB and
/// text import share one copy (no divergence in anchor/timeline behavior).
enum DocumentImportFinalizer {
    private static let logger = Logger(category: "DocumentImportFinalizer")

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
        let anchorDAO = AlignmentAnchorDAO(db: databaseService.writer)

        let alignmentSidecarURL = fileURL.deletingPathExtension().appendingPathExtension(
            "alignment.json")
        if FileManager.default.fileExists(atPath: alignmentSidecarURL.path) {
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
                    // Replace machine anchors but PRESERVE user-placed (human)
                    // anchors so a re-import never destroys manual alignment work.
                    let humanSources: Set<String> = [
                        AlignmentAnchorRecord.Source.moveToNow.rawValue,
                        AlignmentAnchorRecord.Source.searchResult.rawValue,
                        AlignmentAnchorRecord.Source.chapterBoundary.rawValue,
                    ]
                    for existing in try anchorDAO.anchors(for: audiobookID)
                    where !humanSources.contains(existing.source) {
                        try anchorDAO.delete(id: existing.id)
                    }
                    for anchor in resolved { try anchorDAO.upsert(anchor) }
                    try alignmentService.recalculateTimeline()
                    logger.info(
                        "Ingested \(resolved.count)/\(exports.count) anchors from alignment.json (\(exports.count - resolved.count) dropped: block not present locally; user anchors preserved)"
                    )
                }
            } catch {
                logger.error(
                    "Failed to ingest alignment.json sidecar: \(error.localizedDescription)")
            }
        } else {
            // Try CloudKit sync
            let syncService = CloudKitSyncService(db: databaseService.writer)
            let folderURL = fileURL.deletingLastPathComponent()
            let record = try? AudiobookDAO(db: databaseService.writer).get(audiobookID)
            let (title, author) = EPUBAutoImportScanner.anchorLookupMetadata(
                folderURL: folderURL, record: record)
            let durationVal = duration ?? 0.0

            let downloadedAnchors =
                (try? await syncService.downloadAnchors(
                    audiobookID: audiobookID, title: title, author: author,
                    duration: durationVal)) ?? []

            if !downloadedAnchors.isEmpty {
                try? anchorDAO.deleteAll(for: audiobookID)
                for anchor in downloadedAnchors {
                    try? anchorDAO.upsert(anchor)
                }
                try? alignmentService.recalculateTimeline()
                logger.info("Ingested \(downloadedAnchors.count) anchors from CloudKit")
            } else if let firstBlock = blocks.first, let lastBlock = blocks.last,
                let bookDuration = duration
            {
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
                    audioTime: bookDuration,
                    audioEndTime: nil,
                    anchorKind: AlignmentAnchorRecord.AnchorKind.point.rawValue,
                    source: AlignmentAnchorRecord.Source.imported.rawValue,
                    note: "Auto-created: last block",
                    createdAt: AlignmentService.isoFormatter.string(from: Date()),
                    modifiedAt: nil
                )
                try? anchorDAO.deleteAll(for: audiobookID)
                try? anchorDAO.upsert(firstAnchor)
                try? anchorDAO.upsert(lastAnchor)
                try? alignmentService.recalculateTimeline()
                logger.info("Created initial alignment anchors for \(audiobookID)")
            }
        }

        // Always recalculate timeline to ensure chapter-boundary virtual
        // anchors cover blocks even when total duration is unknown.
        if duration == nil {
            try? alignmentService.recalculateTimeline()
            logger.info("Recalculated EPUB timeline (no book duration) for \(audiobookID)")
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
}
