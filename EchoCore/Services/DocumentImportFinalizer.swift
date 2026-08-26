// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import os.log

nonisolated enum DocumentImportNetworkPolicy: Sendable {
    case standard
    case localOnly

    var allowsExternalFetches: Bool {
        self == .standard
    }
}

nonisolated enum DocumentImportNetworkRequest: Equatable, Sendable {
    case ubiquitousSidecarDownload
    case cloudKitAnchors
}

/// The shared post-import tail for document (EPUB / text) ingestion: create
/// initial alignment anchors (alignment.json sidecar → CloudKit → first/last
/// fallback), recalculate the read-along timeline, and post
/// `timelineItemsIngested`. Extracted from `EPUBAutoImportScanner` so EPUB and
/// text import share one copy (no divergence in anchor/timeline behavior).
///
/// **Invariant (J-Space hardening):** every finalize path ends with a
/// materialized timeline — at minimum interpolated `word_timing` rows — so
/// word-level read-along can never silently degrade to an empty table. A sidecar
/// that is found but unresolved, undownloaded from iCloud, or malformed falls
/// back to the interpolation floor instead of writing nothing, and a per-book
/// `SidecarImportSummary` records what happened for Book Settings to surface.
enum DocumentImportFinalizer {
    private static let logger = Logger(category: "DocumentImportFinalizer")
    /// Canonical on `AlignmentAnchorRecord` so this allow-list and the one
    /// `EPUBImportService.replaceAllPreservingUserState` applies across a block
    /// rebuild cannot drift apart.
    private static var humanAnchorSources: Set<String> {
        AlignmentAnchorRecord.humanAnchorSources
    }

    /// Outcome of locating an alignment sidecar next to a book, including the
    /// dataless-iCloud case that a plain `fileExists` check misses.
    private enum SidecarResolution {
        /// A readable, downloaded sidecar at this URL.
        case available(URL)
        /// A sidecar exists only as an undownloaded iCloud placeholder and could
        /// not be pulled in time; a later open retries the download.
        case placeholderPending
        /// No sidecar (or placeholder) found next to the book.
        case none
    }

    static func finalize(
        audiobookID: String,
        blocks: [EPubBlockRecord],
        fileURL: URL,
        duration: TimeInterval?,
        databaseService: DatabaseService,
        networkPolicy: DocumentImportNetworkPolicy = .standard,
        networkRequestObserver:
            (@Sendable (DocumentImportNetworkRequest) -> Void)? = nil
    ) async -> Bool {
        // Create initial system anchors (first block → 0, last block → duration)
        // so every block gets an interpolated timestamp from the start.
        let alignmentService = AlignmentService(
            db: databaseService.writer, audiobookID: audiobookID)

        // Set when sidecar anchors were ingested (fresh or already-matching) and
        // consumed AFTER every timeline recalc has run. Applying sidecar words
        // inside the branch would be silently wiped: any later recalc
        // re-materializes (re-interpolates) the word rows, so the sidecar's
        // words must be re-applied as the LAST step of every finalize.
        var ingestedSidecar: (exports: [AlignmentSidecar.Anchor], localBlockIDs: Set<String>)?
        var appliedSidecarAnchors = false
        // Tracks whether ANY recalc has run, so the tail can guarantee a
        // materialized timeline on every exit path — the fix for the
        // found-but-unresolved sidecar that used to leave `word_timing` empty
        // for audio imports (the sidecar branch and the fallback branch were
        // mutually exclusive, so an unresolved sidecar hit neither).
        var didRecalculateTimeline = false
        // Fix 6 observability snapshot; refined as we learn what the sidecar did.
        var summary = SidecarImportSummary(
            status: .noSidecar, sidecarFound: false, blocksMatched: 0,
            wordsWritten: 0, totalBlocks: blocks.count,
            updatedAt: AlignmentService.isoFormatter.string(from: Date()))

        let resolution =
            networkPolicy.allowsExternalFetches
            ? await resolveSidecar(
                for: fileURL,
                networkRequestObserver: networkRequestObserver)
            : localSidecarResolution(for: fileURL)

        if case .available(let alignmentSidecarURL) = resolution {
            summary.sidecarFound = true
            do {
                let data = try Data(contentsOf: alignmentSidecarURL)
                let exports = try AlignmentSidecar.decode(data)
                if AlignmentSidecar.sourceValidation(for: exports, blocks: blocks) != .current {
                    summary.status = .staleSource
                    logger.info(
                        "alignment.json targets a different source revision, or is a legacy sidecar whose suffixes are unsafe after code-block parsing — falling back to interpolation; existing anchors preserved"
                    )
                } else {
                    // Sidecar block ids are the portable `s<i>-b<j>` suffix. Re-prefix
                    // each with THIS device's audiobookID and drop any whose block isn't
                    // present locally (stale/foreign sidecar) so we never insert orphan
                    // anchors. Resolve FIRST so an all-foreign sidecar leaves existing
                    // anchors intact and falls back to interpolation.
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
                        // A sidecar was found but no portable id resolved to a local
                        // block (block-id schemes diverged — e.g. the reader parsed
                        // the EPUB into different blocks than the sidecar's author).
                        // Do NOT stop here: fall through to the fallback below so the
                        // book still gets an interpolation floor and `word_timing` is
                        // never left empty. Existing anchors are left intact.
                        summary.status = .foundButUnresolved
                        logger.info(
                            "alignment.json: 0 of \(exports.count) anchors resolved to local blocks (portable s<i>-b<j> ids diverge from this import) — falling back to interpolation; existing anchors preserved"
                        )
                    } else {
                        do {
                            if try machineAnchorsMatch(
                                resolved,
                                audiobookID: audiobookID,
                                writer: databaseService.writer
                            ) {
                                logger.debug(
                                    "alignment.json sidecar already ingested for \(audiobookID); refreshing timeline and word timings without rewriting anchors"
                                )
                                try alignmentService.recalculateTimeline()
                            } else {
                                logger.info(
                                    "Found alignment.json sidecar with \(exports.count) anchors.")
                                try replaceMachineAnchors(
                                    with: resolved,
                                    audiobookID: audiobookID,
                                    writer: databaseService.writer,
                                    alignmentService: alignmentService
                                )
                                logger.info(
                                    "Ingested \(resolved.count)/\(exports.count) anchors from alignment.json (\(exports.count - resolved.count) dropped: block not present locally; user anchors preserved)"
                                )
                            }
                            // Stash for the single word-application pass below —
                            // on BOTH paths above: the refresh recalc also rebuilds
                            // (re-interpolates) word rows, so an unchanged sidecar
                            // must re-apply its words on every finalize.
                            didRecalculateTimeline = true
                            ingestedSidecar = (exports, localBlockIDs)
                            appliedSidecarAnchors = true
                            summary.status = .applied
                        } catch {
                            logger.error(
                                "Failed to persist alignment.json anchors: \(error.localizedDescription)"
                            )
                            return false
                        }
                    }
                }
            } catch {
                summary.status = .decodeError
                logger.error(
                    "Failed to ingest alignment.json sidecar (falling back to interpolation): \(error.localizedDescription)"
                )
            }
        } else if case .placeholderPending = resolution {
            summary.sidecarFound = true
            summary.status = .notDownloaded
            logger.info(
                "alignment.json present in iCloud but not downloaded in time for \(audiobookID) — falling back to interpolation; a later open retries the download"
            )
        }

        // Fallback anchors + interpolation floor. Runs whenever we did NOT ingest
        // sidecar anchors (no sidecar, unresolved, undownloaded, or malformed).
        // Anchor-aware, but only when an *expected* sidecar was found and could
        // not be applied: don't downgrade a prior auto-align/manual alignment to
        // a crude first/last pair just because the sidecar was unresolved,
        // undownloaded, or malformed — the book still highlights, just estimated.
        // When there is NO sidecar at all (a fresh or forced import), keep the
        // established "reset replaceable machine anchors to the first/last floor,
        // preserving human anchors" behavior.
        if !appliedSidecarAnchors {
            let hasExistingAnchors =
                ((try? AlignmentAnchorDAO(db: databaseService.writer).anchors(for: audiobookID))
                ?? []).isEmpty == false
            if summary.sidecarFound, hasExistingAnchors {
                do {
                    try alignmentService.recalculateTimeline()
                    didRecalculateTimeline = true
                } catch {
                    logger.error(
                        "Failed to recalculate timeline for \(audiobookID): \(error.localizedDescription)"
                    )
                    return false
                }
            } else if let duration {
                var downloadedAnchors: [AlignmentAnchorRecord] = []
                let folderURL = fileURL.deletingLastPathComponent()
                let record = try? AudiobookDAO(db: databaseService.writer).get(audiobookID)
                let (title, author) = EPUBAutoImportScanner.anchorLookupMetadata(
                    folderURL: folderURL, record: record)

                if networkPolicy.allowsExternalFetches,
                    CloudKitSyncService.canAccessConfiguredContainer()
                {
                    networkRequestObserver?(.cloudKitAnchors)
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
                } else if networkPolicy.allowsExternalFetches {
                    logger.info(
                        "Skipped CloudKit anchor lookup because the app is not entitled for the configured CloudKit container."
                    )
                } else {
                    logger.info(
                        "Skipped CloudKit anchor lookup because this import is local-only."
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
                        didRecalculateTimeline = true
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
                        didRecalculateTimeline = true
                        logger.info("Created initial alignment anchors for \(audiobookID)")
                    } catch {
                        logger.error(
                            "Failed to create initial alignment anchors for \(audiobookID): \(error.localizedDescription)"
                        )
                        return false
                    }
                }
            }
        }

        // Guarantee a materialized timeline on every remaining path: audio-less
        // documents (no duration to anchor against), or an audio import that had
        // neither a usable sidecar nor fallback anchors. `recalculateTimeline`
        // is a no-op on an empty book, so this is always safe.
        if !didRecalculateTimeline {
            do {
                try alignmentService.recalculateTimeline()
                didRecalculateTimeline = true
                logger.info(
                    "Recalculated timeline (interpolation floor) for \(audiobookID)")
            } catch {
                logger.error(
                    "Failed to recalculate timeline for \(audiobookID): \(error.localizedDescription)"
                )
                return false
            }
        }

        // Word-level sidecar timings override the interpolated rows produced by
        // whichever `recalculateTimeline` ran LAST. No-op for word-less or
        // un-ingested sidecars.
        if let ingestedSidecar {
            let application = applySidecarWordTimings(
                exports: ingestedSidecar.exports,
                audiobookID: audiobookID,
                localBlockIDs: ingestedSidecar.localBlockIDs,
                writer: databaseService.writer
            )
            summary.blocksMatched = application.blocksApplied
            summary.wordsWritten = application.wordsApplied
            // `Anchor.words` is optional and omitted when a producer has no
            // per-word timings, so an anchors-only sidecar is the normal shape —
            // every Mac-batch DTW export is one. Applying word timings is a no-op
            // *by definition* for those, and the old unconditional
            // `blocksApplied == 0` downgrade therefore reported a fully
            // successful block-level ingest (1572 anchors resolved) as
            // `.foundButUnresolved`. Only claim failure when the file actually
            // carried word timings and not one block accepted them — the genuine
            // "resolved but nothing aligned" case.
            let sidecarCarriedWords = ingestedSidecar.exports.contains {
                $0.words?.isEmpty == false
            }
            if sidecarCarriedWords, application.blocksApplied == 0 {
                summary.status = .foundButUnresolved
            }
        }

        // Persist the observability snapshot BEFORE notifying, so a UI refresh
        // triggered by the notification reads the up-to-date summary.
        summary.updatedAt = AlignmentService.isoFormatter.string(from: Date())
        BookPreferencesService.saveSidecarSummary(summary, for: audiobookID)

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

    /// Applies the word-level timings a sidecar carried, mirroring the anchor
    /// ingest's re-prefix + drop-foreign resolution: only words whose portable
    /// blockId resolves to a local block are considered, so a foreign or
    /// word-less sidecar contributes nothing. Word-count mismatches are skipped
    /// inside `WordTimingMaterializer.applySidecarWords` (the rows were
    /// materialized from the block's tokenized text, so row count == token
    /// count). Best-effort: a word-timing failure must never fail the import —
    /// the anchors are already ingested and read-along works via interpolation.
    /// Returns the per-pass application so the caller can record how many blocks
    /// took sidecar timings (fix 6) and log which blocks fell back (fix 5).
    @discardableResult
    private static func applySidecarWordTimings(
        exports: [AlignmentSidecar.Anchor],
        audiobookID: String,
        localBlockIDs: Set<String>,
        writer: DatabaseWriter
    ) -> WordTimingMaterializer.SidecarWordApplication {
        var wordsByBlock: [String: [AlignmentSidecar.Anchor.Word]] = [:]
        for export in exports {
            guard let words = export.words, !words.isEmpty else { continue }
            let blockID = AlignmentSidecar.localBlockID(
                export.blockId, audiobookID: audiobookID)
            guard localBlockIDs.contains(blockID) else { continue }
            wordsByBlock[blockID] = words
        }
        guard !wordsByBlock.isEmpty else { return .init() }
        do {
            let application = try WordTimingMaterializer.applySidecarWords(
                audiobookID: audiobookID,
                sidecarWordsByBlock: wordsByBlock,
                writer: writer
            )
            logger.info(
                "Applied sidecar word timings: \(application.blocksApplied)/\(wordsByBlock.count) word-bearing blocks, \(application.wordsApplied) words (\(application.mismatches.count) skipped: word-count mismatch, \(application.blocksWithoutRows) skipped: block unaligned)"
            )
            for mismatch in application.mismatches.prefix(5) {
                logger.info(
                    "  sidecar word-count mismatch: block \(mismatch.blockID) has \(mismatch.blockRows) tokenized rows vs \(mismatch.sidecarWords) sidecar words — kept interpolated"
                )
            }
            if application.mismatches.count > 5 {
                logger.info(
                    "  …and \(application.mismatches.count - 5) more blocks with word-count mismatches"
                )
            }
            return application
        } catch {
            logger.error(
                "Failed to apply sidecar word timings (read-along falls back to interpolation): \(error.localizedDescription)"
            )
            return .init()
        }
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

    private static func machineAnchorsMatch(
        _ anchors: [AlignmentAnchorRecord],
        audiobookID: String,
        writer: DatabaseWriter
    ) throws -> Bool {
        let existing = try writer.read { db in
            try AlignmentAnchorRecord
                .filter(Column("audiobook_id") == audiobookID)
                .filter(!humanAnchorSources.contains(Column("source")))
                .fetchAll(db)
        }
        return anchorsSemanticallyMatch(existing, anchors)
    }

    private static func anchorsSemanticallyMatch(
        _ lhs: [AlignmentAnchorRecord],
        _ rhs: [AlignmentAnchorRecord]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }

        let sortedLHS = lhs.sorted(by: compareAnchors)
        let sortedRHS = rhs.sorted(by: compareAnchors)
        for (left, right) in zip(sortedLHS, sortedRHS) {
            guard left.epubBlockID == right.epubBlockID else { return false }
            guard left.anchorKind == right.anchorKind else { return false }
            guard left.source == right.source else { return false }
            guard timesMatch(left.audioTime, right.audioTime) else { return false }
            guard timesMatch(left.audioEndTime, right.audioEndTime) else { return false }
        }
        return true
    }

    private static func compareAnchors(
        _ lhs: AlignmentAnchorRecord,
        _ rhs: AlignmentAnchorRecord
    ) -> Bool {
        if lhs.epubBlockID != rhs.epubBlockID { return lhs.epubBlockID < rhs.epubBlockID }
        if lhs.source != rhs.source { return lhs.source < rhs.source }
        if lhs.anchorKind != rhs.anchorKind { return lhs.anchorKind < rhs.anchorKind }
        if !timesMatch(lhs.audioTime, rhs.audioTime) { return lhs.audioTime < rhs.audioTime }
        return (lhs.audioEndTime ?? -.infinity) < (rhs.audioEndTime ?? -.infinity)
    }

    private static func timesMatch(_ lhs: TimeInterval?, _ rhs: TimeInterval?) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none):
            return true
        case (.some(let left), .some(let right)):
            return abs(left - right) < 0.001
        default:
            return false
        }
    }

    /// Replays only the alignment-sidecar branch for documents whose text blocks
    /// already exist. This lets a later-arriving or corrected `.alignment.json`
    /// (including one that only just finished downloading from iCloud) light up
    /// read-along — word timings included — without forcing a destructive
    /// document re-import. Called on every open of an already-imported book.
    @discardableResult
    static func finalizeExistingImportIfAlignmentSidecarPresent(
        audiobookID: String,
        fileURL: URL,
        duration: TimeInterval?,
        databaseService: DatabaseService,
        networkPolicy: DocumentImportNetworkPolicy = .standard,
        networkRequestObserver:
            (@Sendable (DocumentImportNetworkRequest) -> Void)? = nil
    ) async -> Bool {
        // Cheap presence check (no download) so the common "no sidecar" reopen
        // stays fast; `finalize` does the actual dataless download once.
        guard hasSidecarOrPlaceholder(for: fileURL) else { return false }

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
            databaseService: databaseService,
            networkPolicy: networkPolicy,
            networkRequestObserver: networkRequestObserver
        )
    }

    // MARK: - Sidecar discovery (incl. dataless iCloud)

    /// Locates an alignment sidecar for `fileURL`, forcing an undownloaded iCloud
    /// placeholder to materialize (with a bounded wait) before returning it.
    /// `fileURL` may be the EPUB, PDF, text, or m4b the book was opened from —
    /// discovery keys off the base name and also matches any `*.alignment.json`
    /// sibling, so an m4b-keyed `<m4b-base>.alignment.json` resolves too.
    private static func resolveSidecar(
        for fileURL: URL,
        fileManager: FileManager = .default,
        networkRequestObserver:
            (@Sendable (DocumentImportNetworkRequest) -> Void)? = nil
    ) async -> SidecarResolution {
        // 1. A sidecar whose real filename is already visible on disk (downloaded
        //    file, or a placeholder that still reports its logical path).
        if let url = alignmentSidecarURL(for: fileURL, fileManager: fileManager) {
            if await ensureDownloaded(
                url,
                fileManager: fileManager,
                networkRequestObserver: networkRequestObserver)
            {
                return .available(url)
            }
            return .placeholderPending
        }
        // 2. A dataless placeholder hidden as `.<name>.alignment.json.icloud`,
        //    which the `.skipsHiddenFiles` scan in (1) cannot see. Map it back to
        //    its logical URL, download, and re-check.
        if let logical = ubiquitousPlaceholderSidecarURL(near: fileURL, fileManager: fileManager) {
            if await ensureDownloaded(
                logical,
                fileManager: fileManager,
                networkRequestObserver: networkRequestObserver),
                fileManager.fileExists(atPath: logical.path)
            {
                return .available(logical)
            }
            return .placeholderPending
        }
        return .none
    }

    /// Resolves only already-materialized sidecars. It never starts a ubiquitous
    /// download and treats dataless placeholders as pending.
    private static func localSidecarResolution(
        for fileURL: URL,
        fileManager: FileManager = .default
    ) -> SidecarResolution {
        if let url = alignmentSidecarURL(for: fileURL, fileManager: fileManager) {
            let values = try? url.resourceValues(forKeys: [
                .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
            ])
            if values?.isUbiquitousItem == true,
                values?.ubiquitousItemDownloadingStatus != .current
            {
                return .placeholderPending
            }
            if fileManager.fileExists(atPath: url.path) {
                return .available(url)
            }
        }
        if ubiquitousPlaceholderSidecarURL(near: fileURL, fileManager: fileManager) != nil {
            return .placeholderPending
        }
        return .none
    }

    /// True when a sidecar (or its iCloud placeholder) exists next to `fileURL`,
    /// without triggering any download. Lets the reopen path skip the (bounded)
    /// download wait when there is nothing to finalize.
    private static func hasSidecarOrPlaceholder(
        for fileURL: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        if alignmentSidecarURL(for: fileURL, fileManager: fileManager) != nil { return true }
        return ubiquitousPlaceholderSidecarURL(near: fileURL, fileManager: fileManager) != nil
    }

    /// Ensures a (possibly ubiquitous) file is downloaded, polling up to ~8s —
    /// enough for a tiny sidecar JSON. Returns `true` once the file is local.
    /// Non-ubiquitous files short-circuit to a plain existence check.
    private static func ensureDownloaded(
        _ url: URL,
        fileManager: FileManager = .default,
        networkRequestObserver:
            (@Sendable (DocumentImportNetworkRequest) -> Void)? = nil
    ) async -> Bool {
        let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey, .ubiquitousItemDownloadingStatusKey,
        ])
        guard values?.isUbiquitousItem == true else {
            return fileManager.fileExists(atPath: url.path)
        }
        if values?.ubiquitousItemDownloadingStatus == .current { return true }
        do {
            networkRequestObserver?(.ubiquitousSidecarDownload)
            try fileManager.startDownloadingUbiquitousItem(at: url)
        } catch {
            logger.error(
                "startDownloadingUbiquitousItem failed for \(url.lastPathComponent): \(error.localizedDescription)"
            )
            return false
        }
        // ~8s: 40 × 200 ms. Sidecars are small; this rarely runs to the deadline.
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(200))
            let status = try? url.resourceValues(
                forKeys: [.ubiquitousItemDownloadingStatusKey]
            ).ubiquitousItemDownloadingStatus
            if status == .current { return true }
        }
        logger.info(
            "alignment.json download did not complete within the wait window for \(url.lastPathComponent)"
        )
        return false
    }

    /// Finds a dataless iCloud sidecar placeholder next to `fileURL`. iCloud
    /// evicts `Foo.alignment.json` to a hidden shadow named
    /// `.Foo.alignment.json.icloud`; this maps any such shadow back to its
    /// logical URL. Enumerates WITHOUT `.skipsHiddenFiles` precisely because the
    /// shadow is hidden.
    private static func ubiquitousPlaceholderSidecarURL(
        near fileURL: URL,
        fileManager: FileManager = .default
    ) -> URL? {
        let directory = fileURL.deletingLastPathComponent()
        guard
            let entries = try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [])
        else { return nil }

        let placeholders =
            entries
            .compactMap { entry -> String? in
                let name = entry.lastPathComponent
                guard name.hasPrefix("."), name.hasSuffix(".icloud") else { return nil }
                let logical = String(name.dropFirst().dropLast(".icloud".count))
                guard logical.lowercased().hasSuffix(".alignment.json") else { return nil }
                return logical
            }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }

        return placeholders.first.map { directory.appending(path: $0) }
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
        let sidecars =
            siblings
            .filter {
                $0.lastPathComponent.localizedCaseInsensitiveCompare(exactName) == .orderedSame
            }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                    == .orderedAscending
            }
        if let match = sidecars.first { return match }

        return
            siblings
            .filter { $0.lastPathComponent.lowercased().hasSuffix(".alignment.json") }
            .sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                    == .orderedAscending
            }
            .first
    }
}
