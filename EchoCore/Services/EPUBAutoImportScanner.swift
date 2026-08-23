// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ZIPFoundation
import os.log

/// The revision pair one stale-source recovery attempt was made against.
///
/// Recovery re-extracts and re-parses the whole document, so it must not run on
/// every open — but it must run again the moment either input changes (the user
/// replaces the EPUB, or drops in a re-exported alignment file). Size plus
/// modification date is the cheapest fingerprint that moves whenever either
/// file's content does and costs no read of either one.
///
/// `nonisolated` for the same reason as `SidecarImportSummary`: under the app
/// targets' MainActor default isolation the synthesized `Codable` conformance
/// would otherwise be main-actor-isolated and unusable from the off-main import
/// task that persists it.
nonisolated struct StaleSourceRecoveryAttempt: Codable, Equatable, Sendable {
    let sourceSize: Int
    let sourceModified: Double
    let sidecarSize: Int
    let sidecarModified: Double

    /// `nil` when either file is missing or has no readable size/date — an
    /// undownloaded iCloud placeholder, for instance. Recovery declines rather
    /// than guessing, and a later open retries once the file materializes.
    init?(sourceURL: URL, sidecarURL: URL) {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        // `URL` caches resource values the first time they are read, so a URL
        // value that outlives a write to the file it names keeps reporting the
        // OLD size and date. This fingerprint exists purely to detect that a
        // file changed, which makes a cached read the one failure that matters:
        // it reports "same revision" and declines the very recovery the user
        // earned by replacing the file. Drop the cache before every read.
        var source = sourceURL
        var sidecar = sidecarURL
        source.removeAllCachedResourceValues()
        sidecar.removeAllCachedResourceValues()
        guard let sourceValues = try? source.resourceValues(forKeys: keys),
            let sidecarValues = try? sidecar.resourceValues(forKeys: keys),
            let sourceSize = sourceValues.fileSize,
            let sidecarSize = sidecarValues.fileSize,
            let sourceModified = sourceValues.contentModificationDate,
            let sidecarModified = sidecarValues.contentModificationDate
        else { return nil }
        self.sourceSize = sourceSize
        self.sourceModified = sourceModified.timeIntervalSinceReferenceDate
        self.sidecarSize = sidecarSize
        self.sidecarModified = sidecarModified.timeIntervalSinceReferenceDate
    }
}

enum EPUBAutoImportScanner {
    private static let logger = Logger(category: "EPUBAutoImport")

    enum ImportOutcome {
        case imported
        case alreadyImported
        case failed(URL, underlying: Error)

        var didImportBlocks: Bool {
            if case .imported = self { return true }
            return false
        }
    }

    /// Scans the given audiobook folder for `.epub` files. When one is found
    /// and no prior EPUB blocks exist in the database, the archive is extracted
    /// and imported via `EPUBImportService`.
    ///
    /// - Parameters:
    ///   - folderURL: The audiobook folder to scan.
    ///   - databaseService: The database service for checking existing imports and persisting blocks.
    ///   - chapters: The parsed chapter list for this audiobook.
    ///   - duration: The total audiobook duration (used for timestamp estimation).
    /// - Returns: `true` when an EPUB was actually imported (blocks created) —
    ///   callers must re-ingest timeline items so `timeline_item` rows reference
    ///   the freshly created block IDs. `false` when skipped or failed.
    @discardableResult
    static func scanAndImportIfNeeded(
        folderURL: URL,
        databaseService: DatabaseService,
        chapters: [Chapter],
        duration: TimeInterval?
    ) async -> Bool {
        // Security-scoped access is managed by SecurityScopeManager in loadFolder.
        // Don't start/stop here — duplicate cycles break file-provider access.

        let audiobookID = folderURL.absoluteString

        // 1. Scan for .epub files in the folder.
        let epubFiles: [URL]
        let contents: [URL]
        var isDir: ObjCBool = false
        let folderIsDirectory =
            FileManager.default.fileExists(atPath: folderURL.path, isDirectory: &isDir)
            && isDir.boolValue
        let targetURL = folderIsDirectory ? folderURL : folderURL.deletingLastPathComponent()

        // When the original URL is a single file (e.g. an M4B opened directly),
        // SecurityScopeManager only covers that file — not its parent directory.
        // Start a temporary scope on the parent so we can enumerate siblings.
        let needsParentScope = !folderIsDirectory
        let didStartParentScope =
            needsParentScope && targetURL.startAccessingSecurityScopedResource()
        defer {
            if didStartParentScope {
                targetURL.stopAccessingSecurityScopedResource()
            }
        }

        do {
            contents = try FileManager.default.contentsOfDirectory(
                at: targetURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: .skipsHiddenFiles
            )
            epubFiles = contents.filter { $0.pathExtension.lowercased() == "epub" }
        } catch {
            logger.warning(
                "Cannot scan folder for EPUB files: \(sanitizedPath(targetURL.path)) — \(error.localizedDescription)"
            )
            return false
        }

        guard
            let epubURL = CompanionDocumentSelector.select(
                documents: epubFiles,
                for: folderURL,
                folderIsDirectory: folderIsDirectory,
                siblingFiles: contents)
        else {
            logger.debug(
                "No unambiguous .epub companion found for: \(sanitizedPath(folderURL.path))")
            return false
        }

        logger.info("Found EPUB file: \(sanitizedPath(epubURL.lastPathComponent))")

        return await importEPUBFile(
            epubURL: epubURL,
            audiobookID: audiobookID,
            databaseService: databaseService,
            chapters: chapters,
            duration: duration,
            force: false
        )
    }

    /// Imports a specific EPUB file for an audiobook, extracting and parsing its blocks.
    /// - Returns: `true` when blocks were imported, `false` when skipped or failed.
    @discardableResult
    static func importEPUBFile(
        epubURL: URL,
        audiobookID: String,
        databaseService: DatabaseService,
        chapters: [Chapter],
        duration: TimeInterval?,
        force: Bool = false,
        finalizerFileURL: URL? = nil,
        networkPolicy: DocumentImportNetworkPolicy = .standard,
        allowStaleSourceRecovery: Bool = true,
        recoveryStore: UserDefaults = .standard,
        networkRequestObserver:
            (@Sendable (DocumentImportNetworkRequest) -> Void)? = nil
    ) async -> Bool {
        let outcome = await importEPUBFileOutcome(
            epubURL: epubURL,
            audiobookID: audiobookID,
            databaseService: databaseService,
            chapters: chapters,
            duration: duration,
            force: force,
            finalizerFileURL: finalizerFileURL,
            networkPolicy: networkPolicy,
            allowStaleSourceRecovery: allowStaleSourceRecovery,
            recoveryStore: recoveryStore,
            networkRequestObserver: networkRequestObserver
        )
        return outcome.didImportBlocks
    }

    static func importEPUBFileOutcome(
        epubURL: URL,
        audiobookID: String,
        databaseService: DatabaseService,
        chapters: [Chapter],
        duration: TimeInterval?,
        force: Bool = false,
        finalizerFileURL: URL? = nil,
        networkPolicy: DocumentImportNetworkPolicy = .standard,
        allowStaleSourceRecovery: Bool = true,
        recoveryStore: UserDefaults = .standard,
        preExtractedDirectory: URL? = nil,
        networkRequestObserver:
            (@Sendable (DocumentImportNetworkRequest) -> Void)? = nil
    ) async -> ImportOutcome {
        // Security-scoped access is managed by SecurityScopeManager in loadFolder.
        // Don't start/stop here — duplicate cycles break file-provider access.

        // Check if EPUB blocks are already imported for this audiobook.
        if !force {
            // `allBlocks`, not `visibleBlocks`: the question is "has this
            // document ever been imported", and a re-import now carries
            // `is_hidden` across. A user who excluded every chapter from the
            // narration outline has zero VISIBLE blocks, so a `visibleBlocks`
            // guard would answer "not imported" forever and re-run the full
            // destructive rebuild on every single open. (It used to self-heal
            // only because the old `deleteAll` + insert reset `is_hidden`.)
            let alreadyImported =
                (try? EPubBlockDAO(db: databaseService.writer).allBlocks(for: audiobookID)
                    .isEmpty) == false
            if alreadyImported {
                logger.debug(
                    "EPUB blocks already exist for \(sanitizedPath(audiobookID)); skipping auto-import."
                )
                // The finalizer re-runs the sidecar branch and rewrites the
                // per-book summary, so the verdict read immediately below is
                // this open's verdict, not a stale one.
                _ = await DocumentImportFinalizer.finalizeExistingImportIfAlignmentSidecarPresent(
                    audiobookID: audiobookID,
                    fileURL: finalizerFileURL ?? epubURL,
                    duration: duration,
                    databaseService: databaseService,
                    networkPolicy: networkPolicy,
                    networkRequestObserver: networkRequestObserver
                )
                if allowStaleSourceRecovery,
                    let recovered = await recoverStaleSourceIfPossible(
                        epubURL: epubURL,
                        audiobookID: audiobookID,
                        databaseService: databaseService,
                        chapters: chapters,
                        duration: duration,
                        finalizerFileURL: finalizerFileURL,
                        networkPolicy: networkPolicy,
                        recoveryStore: recoveryStore,
                        networkRequestObserver: networkRequestObserver
                    )
                {
                    // The recovery re-import COMMITTED its block rebuild before
                    // the finalizer ran, so its real outcome has to reach the
                    // caller. Collapsing a `.failed` finalize to
                    // `.alreadyImported` would tell the caller "nothing happened"
                    // about a book whose blocks were just rewritten, and it would
                    // skip the timeline re-ingest that leaves it usable.
                    return recovered
                }
                return .alreadyImported
            }
        }

        // Try downloading CloudKit anchors first if not forced, but wait, if blocks aren't extracted yet, CloudKit anchors need the blocks.
        // So we must extract EPUB first, insert blocks, then check CloudKit before doing auto-alignment.

        // Extract the EPUB archive to a cache directory — unless the caller
        // already expanded this exact archive. Copying and unzipping a book
        // twice is not free here: `extractEPUB` and `parseEPUBBlocks` are both
        // synchronous under this target's MainActor default isolation, so each
        // pass is main-thread time. Stale-source recovery expands the archive to
        // validate the alignment file and hands that directory straight over.
        let extractedDir: URL
        if let preExtractedDirectory {
            extractedDir = preExtractedDirectory
        } else {
            let safeID = SafeFileName.fromAudiobookID(audiobookID)
            let cacheDir: URL
            do {
                cacheDir = try prepareCacheDirectory(safeID: safeID)
            } catch {
                logger.error(
                    "Failed to prepare EPUB cache directory: \(error.localizedDescription)")
                return .failed(epubURL, underlying: error)
            }
            do {
                extractedDir = try extractEPUB(epubURL, to: cacheDir, safeID: safeID)
            } catch {
                logger.error(
                    "Failed to extract EPUB \(sanitizedPath(epubURL.lastPathComponent)): \(error.localizedDescription)"
                )
                return .failed(epubURL, underlying: error)
            }
        }

        // Import extracted EPUB blocks.
        do {
            let assetStorage = EPUBAssetStorage(databaseService: databaseService)
            let importer = EPUBImportService(assetStorage: assetStorage)
            let blocks = try await importer.import(
                audiobookID: audiobookID,
                epubURL: extractedDir,
                chapters: chapters,
                bookDuration: duration
            )
            logger.info(
                "Auto-imported \(blocks.count) EPUB blocks for \(sanitizedPath(epubURL.lastPathComponent))"
            )

            let finalized = await DocumentImportFinalizer.finalize(
                audiobookID: audiobookID, blocks: blocks, fileURL: finalizerFileURL ?? epubURL,
                duration: duration, databaseService: databaseService,
                networkPolicy: networkPolicy,
                networkRequestObserver: networkRequestObserver)
            if finalized {
                return .imported
            }
            return .failed(epubURL, underlying: ScannerError.finalizationFailed(url: epubURL))
        } catch {
            logger.error("EPUB auto-import failed: \(error.localizedDescription)")
            return .failed(epubURL, underlying: error)
        }
    }

    // MARK: - Stale-source recovery

    /// The recovery fuse, as a pure decision so the no-loop property can be
    /// proven without a filesystem, a database, or a clock.
    ///
    /// Recovery costs a full extract + re-parse, so it must never run on an
    /// ordinary open. It runs when the last finalize actually reported
    /// `.staleSource`, both files could be fingerprinted, and that fingerprint
    /// differs from the one already tried. Because the caller records the
    /// fingerprint *before* attempting, a repeat on unchanged inputs — the loop —
    /// is impossible: the second call sees `attempt == lastAttempt`.
    static func shouldAttemptStaleSourceRecovery(
        status: SidecarImportSummary.Status?,
        attempt: StaleSourceRecoveryAttempt?,
        lastAttempt: StaleSourceRecoveryAttempt?
    ) -> Bool {
        guard status == .staleSource, let attempt else { return false }
        return attempt != lastAttempt
    }

    /// Repairs the `.staleSource` state automatically when — and only when — the
    /// document on disk would validate against the alignment file.
    ///
    /// `.staleSource` does not mean the alignment file is out of date. It means
    /// the *persisted* `epub_block` text no longer matches it: the user replaced
    /// the EPUB, or re-imported an edition the sidecar was not produced from, and
    /// `AlignmentSidecar.sourceValidation` fails closed on the first mismatching
    /// anchor. When the file sitting next to the book NOW is the one the sidecar
    /// was produced from, the database is simply behind, and re-importing fixes it
    /// — which is only safe to do automatically because
    /// `EPUBImportService.replaceAllPreservingUserState` carries hidden/coloured
    /// blocks, human anchors, notes, memos, and cards across the rebuild.
    ///
    /// Ordering matters: the dry run parses and validates BEFORE any write, so a
    /// book whose text genuinely diverged is never re-imported on a guess — but
    /// only because `sidecarProvesDocumentIdentity` first refuses the verdicts
    /// that are not actually about the text. See that function.
    ///
    /// - Returns: `nil` when nothing was attempted, otherwise the real outcome of
    ///   the forced re-import — including `.failed`, which the caller must not
    ///   flatten to "nothing happened" because the block rebuild has committed by
    ///   then.
    private static func recoverStaleSourceIfPossible(
        epubURL: URL,
        audiobookID: String,
        databaseService: DatabaseService,
        chapters: [Chapter],
        duration: TimeInterval?,
        finalizerFileURL: URL?,
        networkPolicy: DocumentImportNetworkPolicy,
        recoveryStore: UserDefaults,
        networkRequestObserver:
            (@Sendable (DocumentImportNetworkRequest) -> Void)?
    ) async -> ImportOutcome? {
        // 1. Both files must be on disk: the sidecar to validate against, the
        //    source to re-parse. A dataless iCloud sidecar has no attributes to
        //    fingerprint and is left for a later open to download.
        let sidecarURL = DocumentImportFinalizer.alignmentSidecarURL(
            for: finalizerFileURL ?? epubURL)
        let attempt = sidecarURL.flatMap {
            StaleSourceRecoveryAttempt(sourceURL: epubURL, sidecarURL: $0)
        }

        // 2. The fuse: act only on the one state this repairs, and only once per
        //    (document, alignment) revision pair.
        guard
            shouldAttemptStaleSourceRecovery(
                status: BookPreferencesService.loadSidecarSummary(
                    for: audiobookID, store: recoveryStore)?.status,
                attempt: attempt,
                lastAttempt: BookPreferencesService.loadStaleSourceRecoveryAttempt(
                    for: audiobookID, store: recoveryStore))
        else { return nil }
        guard let sidecarURL, let attempt else { return nil }

        // Burn the fuse BEFORE the work, not after: a parse that throws, or a
        // process kill mid-import, must not earn a fresh attempt on the next
        // open. Only a genuinely new revision does — or an abandonment, which
        // rearms it explicitly below.
        BookPreferencesService.saveStaleSourceRecoveryAttempt(
            attempt, for: audiobookID, store: recoveryStore)

        // Cancellation means the user left this book. Nothing has been written
        // yet at these two points, so re-arm the fuse and leave: the repair is
        // still owed, and burning it here would strand the book forever.
        func abandonBeforeAnyWrite() -> ImportOutcome? {
            BookPreferencesService.saveStaleSourceRecoveryAttempt(
                nil, for: audiobookID, store: recoveryStore)
            return nil
        }
        if Task.isCancelled { return abandonBeforeAnyWrite() }

        // 3. Dry run: parse the document that is on disk now and ask whether the
        //    sidecar validates against THOSE blocks. Nothing is written yet.
        let safeID = SafeFileName.fromAudiobookID(audiobookID)
        let probeDir: URL
        do {
            let cacheDir = try prepareCacheDirectory(safeID: safeID)
            probeDir = try extractEPUB(epubURL, to: cacheDir, safeID: safeID)
        } catch {
            logger.info(
                "Stale-source recovery: could not extract the document to re-check it — \(error.localizedDescription)"
            )
            return nil
        }
        // The probe leaves no cache residue when it declines. When it proceeds it
        // hands the expansion to the import instead of deleting it, so the
        // archive is copied and unzipped once rather than twice — both passes are
        // synchronous main-actor work on the book-open path.
        var handedOffToImport = false
        defer {
            if !handedOffToImport { try? FileManager.default.removeItem(at: probeDir) }
        }
        if Task.isCancelled { return abandonBeforeAnyWrite() }

        do {
            let data = try Data(contentsOf: sidecarURL)
            let exports = try AlignmentSidecar.decode(data)
            guard sidecarProvesDocumentIdentity(exports) else { return nil }
            let parsed = try parseEPUBBlocks(audiobookID: audiobookID, epubURL: probeDir)
            let validation = AlignmentSidecar.sourceValidation(
                for: exports, blocks: parsed.blocks)
            guard validation == .current else {
                logger.info(
                    "Stale-source recovery declined: the document on disk still does not match the alignment file (\(String(describing: validation)))"
                )
                return nil
            }
        } catch {
            logger.info(
                "Stale-source recovery: could not re-check the document against the alignment file — \(error.localizedDescription)"
            )
            return nil
        }
        if Task.isCancelled { return abandonBeforeAnyWrite() }

        // 4. The document on disk IS the one the alignment file was produced
        //    from. Re-import it for real. `allowStaleSourceRecovery: false` makes
        //    the no-loop property structural rather than an inference from
        //    `force` skipping the branch above.
        logger.info(
            "Stale-source recovery: the document on disk matches the alignment file — re-importing to restore read-along"
        )
        handedOffToImport = true
        let outcome = await importEPUBFileOutcome(
            epubURL: epubURL,
            audiobookID: audiobookID,
            databaseService: databaseService,
            chapters: chapters,
            duration: duration,
            force: true,
            finalizerFileURL: finalizerFileURL,
            networkPolicy: networkPolicy,
            allowStaleSourceRecovery: false,
            recoveryStore: recoveryStore,
            preExtractedDirectory: probeDir,
            networkRequestObserver: networkRequestObserver
        )
        if case .failed(_, let underlying) = outcome {
            // `EPUBImportService` committed the block rebuild in its own
            // transaction before the finalizer ran, so a failure here leaves the
            // book rebuilt but with its timeline un-rebuilt. Re-arm the fuse so
            // the next open can finish the repair rather than leaving it
            // half-done for the life of these two files.
            logger.error(
                "Stale-source recovery re-imported the blocks but could not finalize; re-arming for the next open — \(underlying.localizedDescription)"
            )
            BookPreferencesService.saveStaleSourceRecoveryAttempt(
                nil, for: audiobookID, store: recoveryStore)
        }
        return outcome
    }

    /// Whether an alignment file makes a checkable claim about *which document*
    /// it describes.
    ///
    /// `AlignmentSidecar.sourceValidation` short-circuits when no anchor carries
    /// a `sourceBlockIdentity`: for a legacy file its verdict is a pure function
    /// of "do these blocks contain a code block", and says nothing whatever about
    /// the text. That makes `.current` useless as evidence here — worse than
    /// useless. `.staleSource` from a legacy sidecar MEANS the persisted blocks
    /// contained code, so the only way a re-parse can flip the verdict to
    /// `.current` is if the document on disk parses with NO code, i.e. if it is a
    /// *different document*. Trusting the legacy verdict would fire the
    /// destructive re-import in precisely the case it must refuse: a user drops
    /// an unrelated EPUB into the folder, `CompanionDocumentSelector` picks it up,
    /// and the book's blocks, anchors, word timings and study pins are silently
    /// replaced with another book's.
    ///
    /// So require a real identity claim. A legacy sidecar is not repairable
    /// automatically; it needs a re-export, or an explicit Replace Document.
    static func sidecarProvesDocumentIdentity(_ exports: [AlignmentSidecar.Anchor]) -> Bool {
        guard exports.contains(where: { $0.sourceBlockIdentity != nil }) else {
            logger.info(
                "Stale-source recovery declined: the alignment file carries no source identities, so it cannot prove which document it describes"
            )
            return false
        }
        return true
    }

    // MARK: - Anchor lookup

    /// Title/author to use for the CloudKit anchor lookup. Prefer the persisted
    /// audiobook row (authoritative — for ABS books this is the real ABS metadata);
    /// fall back to folder-name derivation for not-yet-persisted local books.
    static func anchorLookupMetadata(folderURL: URL, record: AudiobookRecord?) -> (
        title: String, author: String
    ) {
        let title = record?.title ?? folderURL.lastPathComponent
        let author = record?.author ?? folderURL.deletingLastPathComponent().lastPathComponent
        return (title, author)
    }

    // MARK: - Private helpers

    /// Creates (or reuses) the cache directory `Caches/EPUBUnpacked/<safeID>/`.
    private static func prepareCacheDirectory(safeID: String) throws -> URL {
        guard
            let caches = FileManager.default.urls(
                for: .cachesDirectory, in: .userDomainMask
            ).first
        else {
            throw ScannerError.cachesUnavailable
        }
        let dir =
            caches
            .appendingPathComponent("EPUBUnpacked", isDirectory: true)
            .appendingPathComponent(safeID, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Extracts the `.epub` archive to a uniquely-named subdirectory under
    /// `<cacheDir>/` to prevent races when two imports of the same EPUB
    /// happen concurrently.  The caller should atomically move the content
    /// into its final location after extraction.
    private static func extractEPUB(_ epubURL: URL, to cacheDir: URL, safeID: String) throws -> URL
    {
        let destDir = cacheDir.appendingPathComponent(
            "\(safeID)_\(UUID().uuidString)_content", isDirectory: true)

        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        // Copy the EPUB into the cache directory so Archive opens a local file
        // rather than a file-provider-managed one. This avoids permission issues
        // with File Provider Storage paths. The copy is uniquely named and
        // removed after extraction — a shared name raced when two imports ran
        // concurrently (remove/copy interleaving truncated the archive).
        let cachedEPUB = cacheDir.appendingPathComponent("\(safeID)_\(UUID().uuidString).epub")
        defer { try? FileManager.default.removeItem(at: cachedEPUB) }
        do {
            let started = epubURL.startAccessingSecurityScopedResource()
            defer { if started { epubURL.stopAccessingSecurityScopedResource() } }

            var copyError: Error?
            let coordinator = NSFileCoordinator()
            var coordinatorError: NSError?
            coordinator.coordinate(
                readingItemAt: epubURL, options: .withoutChanges, error: &coordinatorError
            ) { url in
                do {
                    try FileManager.default.copyItem(at: url, to: cachedEPUB)
                } catch {
                    copyError = error
                }
            }
            if let error = copyError ?? coordinatorError {
                throw error
            }
        } catch {
            logger.error(
                "Failed to copy EPUB to cache at \(sanitizedPath(cachedEPUB.path)): \(error.localizedDescription)"
            )
            throw ScannerError.invalidArchive(url: epubURL)
        }

        let archive: Archive
        do {
            logger.debug("Opening EPUB archive from cache: \(sanitizedPath(cachedEPUB.path))")
            archive = try Archive(url: cachedEPUB, accessMode: .read)
        } catch {
            logger.error(
                "Failed to open EPUB archive at \(sanitizedPath(cachedEPUB.path)): \(error.localizedDescription) (type: \(type(of: error)))"
            )
            throw ScannerError.invalidArchive(url: epubURL)
        }

        // Validate mimetype.
        if let mimetypeEntry = archive["mimetype"] {
            var mimetypeData = Data()
            _ = try archive.extract(mimetypeEntry) { chunk in
                mimetypeData.append(chunk)
            }
            let mimetypeString = String(data: mimetypeData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard mimetypeString == "application/epub+zip" else {
                throw ScannerError.invalidEPUB(path: epubURL.path)
            }
        }

        var totalExtracted: UInt64 = 0
        for entry in archive {
            guard entry.type == .file else { continue }
            // Reject decompression bombs before touching the filesystem (audit §6.1).
            do {
                totalExtracted = try ArchiveExtractionLimits.checkedTotal(
                    addingEntryOfSize: entry.uncompressedSize, to: totalExtracted
                )
            } catch {
                throw ScannerError.invalidArchive(url: epubURL)
            }
            // Validate the entry path *before* creating any directory or
            // writing any file, so a hostile archive can never coax us into
            // touching the filesystem outside `destDir`.
            let destination = try safeDestination(for: entry.path, within: destDir)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            _ = try archive.extract(entry, to: destination)
        }

        // Apply data protection after extraction. Setting it on the directory
        // first can make simulator writes fail with EPERM, while device files
        // still need explicit protection once ZIPFoundation has created them.
        #if os(iOS) && !targetEnvironment(simulator)
            try applyDataProtectionRecursively(to: destDir)
        #endif

        logger.debug("Extracted EPUB to \(sanitizedPath(destDir.path))")
        return destDir
    }

    private static func applyDataProtectionRecursively(to root: URL) throws {
        guard
            let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey]
            )
        else { return }

        let descendants = enumerator.compactMap { $0 as? URL }
            .sorted { $0.path.count > $1.path.count }

        for url in descendants {
            try (url as NSURL).setResourceValue(
                URLFileProtection.complete, forKey: .fileProtectionKey)
        }
        try (root as NSURL).setResourceValue(
            URLFileProtection.complete, forKey: .fileProtectionKey)
    }

    /// Resolves a ZIP entry path to its on-disk destination, guaranteeing the
    /// result stays inside `root` (zip-slip / directory-traversal defense).
    ///
    /// ZIPFoundation's `unzipItem(at:to:)` performs this check internally, but
    /// we extract entries individually (to validate the mimetype and stream
    /// each entry), so the guard is ours to enforce. Throws when the entry path
    /// is absolute or escapes `root` via `..` segments.  (CODE_AUDIT.md §6.1)
    static func safeDestination(for entryPath: String, within root: URL) throws -> URL {
        // Absolute entry paths have no legitimate use in an EPUB and would
        // otherwise be silently re-rooted by `appendingPathComponent`.
        guard !entryPath.hasPrefix("/") else {
            throw ScannerError.unsafeEntryPath(entryPath)
        }

        let destination = root.appendingPathComponent(entryPath).standardizedFileURL
        let rootPath = root.standardizedFileURL.path

        // After normalizing `..` segments, the destination must remain within
        // root — i.e. be root itself or a path beneath `root/`.
        guard destination.path == rootPath || destination.path.hasPrefix(rootPath + "/") else {
            throw ScannerError.unsafeEntryPath(entryPath)
        }

        return destination
    }

    /// Sanitizes a filesystem path for safe logging (strips the user's home
    /// directory prefix to avoid leaking the full path in logs).
    private static func sanitizedPath(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path.hasPrefix(home) {
            return "~" + path.dropFirst(home.count)
        }
        return path
    }
}

nonisolated enum CompanionDocumentSelector {
    static func select(
        documents: [URL],
        for bookURL: URL,
        folderIsDirectory: Bool,
        siblingFiles: [URL]
    ) -> URL? {
        let orderedDocuments = documents.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }
        if folderIsDirectory { return orderedDocuments.first }

        let bookStem = bookURL.deletingPathExtension().lastPathComponent
        if let exactMatch = orderedDocuments.first(where: {
            $0.deletingPathExtension().lastPathComponent.compare(
                bookStem, options: [.caseInsensitive, .diacriticInsensitive]
            ) == .orderedSame
        }) {
            return exactMatch
        }

        let audioSiblings = siblingFiles.filter(PlaylistManager.isAudioFile)
        guard audioSiblings.count == 1, orderedDocuments.count == 1 else { return nil }
        return orderedDocuments[0]
    }
}

// MARK: - Errors

private enum ScannerError: LocalizedError {
    case cachesUnavailable
    case invalidArchive(url: URL)
    case invalidEPUB(path: String)
    case unsafeEntryPath(String)
    case finalizationFailed(url: URL)

    var errorDescription: String? {
        switch self {
        case .cachesUnavailable:
            return "Caches directory is unavailable"
        case .invalidArchive(let url):
            return "Cannot open archive: \(url.lastPathComponent)"
        case .invalidEPUB(let path):
            return "File is not a valid EPUB: \(path)"
        case .unsafeEntryPath(let path):
            return "EPUB contains an unsafe entry path: \(path)"
        case .finalizationFailed(let url):
            return "Could not save EPUB import: \(url.lastPathComponent)"
        }
    }
}
