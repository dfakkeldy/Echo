// SPDX-License-Identifier: GPL-3.0-or-later
//
//  MacBatchProcessingService.swift
//  Echo macOS
//
//  macOS batch queue: DB-backed, survives restart, runs the full per-book
//  pipeline (import → transcribe → align → word timings) one book at a time.
//  Wraps the shared `BatchQueueRunner` with real stages and exposes queue
//  state for `MacBatchQueueView`.
//

import AVFoundation
import Foundation
import Observation
import os.log

/// macOS batch queue: DB-backed, survives restart, runs import → transcribe →
/// align → word timings per book. Wraps the shared `BatchQueueRunner` with real
/// stages and exposes queue state for `MacBatchQueueView`.
///
/// Each item persists the source audio file as a macOS **security-scoped
/// bookmark** so it stays reachable after relaunch. The book's `audiobookID`
/// is the source directory's `absoluteString`, matching the formula used by
/// `EPUBImportCoordinator` and `MacAlignmentService` so blocks, anchors, and
/// word timings all key off the same identifier.
@MainActor
@Observable
final class MacBatchProcessingService {
    private let dbService: DatabaseService
    private let settings: SettingsManager
    private let dao: BatchQueueDAO
    private let alignmentService = MacAlignmentService()
    private let logger = Logger(category: "MacBatchProcessing")

    private(set) var items: [BatchQueueRecord] = []
    private(set) var isProcessing = false
    private var runner: BatchQueueRunner?

    init(dbService: DatabaseService, settings: SettingsManager) {
        self.dbService = dbService
        self.settings = settings
        self.dao = BatchQueueDAO(db: dbService.writer)
    }

    /// Resets items interrupted by a previous quit, then resumes draining.
    ///
    /// Attached to the WindowGroup root via `.task`, which fires once per *view*
    /// appearance — NOT once per app launch. On macOS the window can be closed
    /// while this App-level service keeps draining, then reopened (Dock / Window
    /// menu), re-firing `.task`. Guard against that: `recoverInFlight()` rewrites
    /// every importing/transcribing/aligning row back to `.queued` (progress 0,
    /// `started_at` NULL), which would clobber the row the live runner is
    /// mid-processing and, if the drain has just finished (`runner == nil` again),
    /// silently re-run a finished book from scratch. A relaunch-style recovery is
    /// only ever correct when nothing is draining, so bail out if a runner is
    /// live: the existing drain already owns the in-flight rows.
    func resumeOnLaunch() {
        guard runner == nil else { return }
        try? dao.recoverInFlight()
        refresh()
        start()
    }

    /// Adds one audio file to the persistent queue and (re)starts processing.
    ///
    /// The file is persisted as a security-scoped bookmark so the queue can
    /// re-open it after an app relaunch. Creating a `.withSecurityScope`
    /// bookmark requires the `com.apple.security.files.bookmarks.app-scope`
    /// entitlement, which the sandboxed macOS target already declares.
    ///
    /// `companionEPUB`, when supplied, is bookmarked **now** while the
    /// user-selected folder's security scope is still active (see
    /// `FolderAudioScanner.enqueueFolder`). The companion lives at a
    /// sibling path that the audio file's own bookmark does NOT cover, so under
    /// the sandbox the EPUB read would fail at processing time without its own
    /// scope. We persist a separate bookmark and resolve it in `makeStages()`.
    func enqueue(fileURL: URL, companionEPUB: URL? = nil) throws {
        let bookmark = try fileURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil)
        // Capture the companion EPUB's scope while the folder scope is live.
        // A failure here must not silently drop the companion: log and proceed
        // with a nil bookmark so the item still enqueues (import will then fail
        // with a clear error rather than completing an empty book).
        let companionBookmark: Data?
        if let companionEPUB {
            do {
                companionBookmark = try companionEPUB.bookmarkData(
                    options: .withSecurityScope,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil)
            } catch {
                logger.error(
                    "Failed to bookmark companion EPUB \(companionEPUB.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                companionBookmark = nil
            }
        } else {
            companionBookmark = nil
        }
        // Key off the source directory so blocks/anchors/word-timings written
        // during processing match the importer's `folderURL.absoluteString`.
        let audiobookID = fileURL.deletingLastPathComponent().absoluteString
        _ = try dao.enqueue(
            BatchQueueRecord(
                audiobookID: audiobookID,
                sourceBookmark: bookmark,
                companionBookmark: companionBookmark,
                displayName: fileURL.deletingPathExtension().lastPathComponent,
                queuePosition: 0,
                status: .queued,
                progress: 0,
                enqueuedAt: ISO8601DateFormatter().string(from: Date())))
        refresh()
        start()
    }

    /// Adds a standalone EPUB to the persistent queue as a **text-only narration**
    /// item (`kind: .narrate`) and (re)starts processing.
    ///
    /// Unlike `enqueue(fileURL:companionEPUB:)`, the EPUB itself is the bookmarked
    /// primary source — there is no companion audio. `audiobookID` derives from
    /// the EPUB's parent directory `absoluteString`, matching the importer's
    /// `folderURL.absoluteString` scheme so synthesized tracks, EPUB blocks, and
    /// `.synthesized` anchors all key off the same identifier. (Device-local id
    /// portability is tracked separately, consistent with the align path.)
    func enqueueNarration(epubURL: URL) throws {
        let bookmark = try epubURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil)
        // One EPUB = one book, so key off the EPUB's own URL (not its parent
        // directory): multiple EPUBs in a single folder must not share an id.
        let audiobookID = epubURL.absoluteString
        _ = try dao.enqueue(
            BatchQueueRecord(
                audiobookID: audiobookID,
                sourceBookmark: bookmark,
                companionBookmark: nil,
                displayName: epubURL.deletingPathExtension().lastPathComponent,
                queuePosition: 0,
                status: .queued,
                progress: 0,
                kind: .narrate,
                enqueuedAt: ISO8601DateFormatter().string(from: Date())))
        refresh()
        start()
    }

    /// Starts draining the queue if not already running.
    ///
    /// Guards against a lost-wakeup race: `await runner.drain()` is a suspension
    /// point, so an `enqueue()` (also on the main actor) can insert a new
    /// `.queued` row *after* the drain loop observed an empty queue but *before*
    /// the continuation here clears `runner`. That just-enqueued item would
    /// otherwise sit orphaned with no running drain. After clearing `runner` we
    /// re-check `dao.nextQueued()`; if work appeared during the gap we restart.
    func start() {
        guard runner == nil else { return }
        let runner = BatchQueueRunner(dao: dao, stages: makeStages())
        self.runner = runner
        Task { [weak self] in
            guard let self else { return }
            self.isProcessing = true
            await runner.drain()
            self.runner = nil
            self.refresh()
            // Re-check for work enqueued during the drain→clear gap.
            if (try? self.dao.nextQueued()) != nil {
                self.start()
            } else {
                self.isProcessing = false
            }
        }
    }

    func refresh() { items = (try? dao.allItems()) ?? [] }
    func clearCompleted() {
        try? dao.deleteCompleted()
        refresh()
    }

    /// Removes a still-queued item from the queue (no-op if the runner has already
    /// started it). Only the queue row is deleted — any rendered chapters for the
    /// book stay in the library. Mirrors `clearCompleted()`: DAO write then refresh.
    func removeQueued(_ item: BatchQueueRecord) {
        guard let id = item.id else { return }
        try? dao.deleteQueued(id: id)
        refresh()
    }

    /// Whether a narrated book has at least one rendered chapter on disk. Lets the
    /// queue offer "Open" for a `.failed` narrate item that still produced playable
    /// chapters before it stopped (e.g. a mid-book vocoder failure).
    func hasRenderedTracks(for audiobookID: String) -> Bool {
        ((try? TrackDAO(db: dbService.writer).tracks(for: audiobookID).count) ?? 0) > 0
    }

    // MARK: - Stages

    private func makeStages() -> BatchQueueRunner.Stages {
        let dbService = self.dbService
        let settings = self.settings
        let alignmentService = self.alignmentService
        let logger = self.logger
        return .init(run: { [weak self] record, rawProgress in
            // Wrap the runner's DAO-writing progress callback so each stage
            // transition ALSO refreshes the in-memory `items` snapshot. Without
            // this, the runner persists importing→transcribing→aligning to the
            // DB but `MacBatchQueueView` (bound to `items`) never re-reads it
            // while a book is processing, so the icon/ProgressView never advance.
            // A nested func (vs a closure-typed `let`) stays non-escaping so it
            // can legally call the non-escaping `rawProgress` parameter.
            @MainActor func progress(
                _ status: BatchItemStatus, _ value: Double, _ message: String?
            ) {
                rawProgress(status, value, message)
                self?.refresh()
            }

            // Text-only EPUB narration: synthesize on-device audio for an EPUB
            // with no companion audiobook, instead of the align pipeline. The
            // EPUB itself is the bookmarked source, so this branch resolves its
            // own bookmark and returns early, leaving the audio-oriented align
            // body below untouched.
            if record.kind == .narrate {
                var narrateStale = false
                let epubURL = try URL(
                    resolvingBookmarkData: record.sourceBookmark,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &narrateStale)
                if narrateStale {
                    logger.warning(
                        "Bookmark stale for \(record.displayName, privacy: .public); continuing this run"
                    )
                }
                guard epubURL.startAccessingSecurityScopedResource() else {
                    throw BatchProcessingError.cannotAccessFile(epubURL.lastPathComponent)
                }
                defer { epubURL.stopAccessingSecurityScopedResource() }

                // Per-EPUB id (matches enqueueNarration) — see importEPUBOnly.
                let audiobookID = epubURL.absoluteString

                // 1) Import the EPUB's blocks (no audio). `chapterIndex` comes from
                //    the EPUB's own structure, so empty audio `chapters` is fine —
                //    the same path the iOS study-book reader uses.
                progress(.importing, 0.05, "Importing EPUB…")
                try await self?.importEPUBOnly(
                    epubURL: epubURL, audiobookID: audiobookID, dbService: dbService)

                let blocks =
                    (try? EPubBlockDAO(db: dbService.writer).blocks(for: audiobookID)) ?? []
                let chapters = NarrationChapterPlanner.plan(from: blocks)
                guard !chapters.isEmpty else {
                    throw BatchProcessingError.emptyImport(epubURL.lastPathComponent)
                }

                // 2) Synthesize each chapter on-device into the shared narration
                //    cache. The stage closure inherits the runner's @MainActor
                //    isolation, so the @MainActor NarrationService is constructed
                //    and driven inline. A thrown synthesis error is isolated to
                //    this book by the runner (marked `.failed`).
                // Honor the user's shared narration-voice preference (the same
                // `narrationVoiceID` the iOS player reads), falling back to the
                // catalog default when unset or unknown.
                let voice =
                    VoiceCatalog.voice(for: VoiceID(settings.narrationVoiceID))?.id
                    ?? VoiceCatalog.default.id
                // Built via a closure so a failed chapter can retry with a FRESH
                // engine — re-initialising KokoroAne resets the ANE state that an
                // inference failure (e.g. the Kokoro vocoder tripping on the Neural
                // Engine) can leave wedged. The closure also injects the user's
                // pronunciation overrides so each (re-)created service honors them.
                @MainActor func makeService() -> NarrationService {
                    NarrationService(
                        db: dbService.writer, audiobookID: audiobookID,
                        tts: NarrationEngineFactory.make(),
                        audioWriter: AVFoundationAudioWriter(),
                        cacheDirectory: NarrationCache.directory(), state: NarrationState(),
                        pronunciationOverrides: { PronunciationOverrideStore.shared.overrides() })
                }
                var service = makeService()
                var skipped = 0
                for (n, chapter) in chapters.enumerated() {
                    try Task.checkCancellation()

                    // Resume: a chapter already rendered by a prior (partial) run is
                    // cached on disk with its TrackRecord, so skip it instead of
                    // re-burning the ANE — mirrors the iOS render loop.
                    let cachedFile = NarrationCache.directory().appendingPathComponent(
                        NarrationFileNaming.chapterFileName(
                            audiobookID: audiobookID, chapterIndex: chapter.index, voice: voice))
                    if FileManager.default.fileExists(atPath: cachedFile.path) { continue }

                    progress(
                        .transcribing,
                        0.1 + 0.85 * Double(n) / Double(chapters.count),
                        "Narrating chapter \(n + 1) of \(chapters.count)…")
                    do {
                        try await service.renderChapter(
                            chapterIndex: chapter.index, chapterNumber: chapter.displayNumber,
                            blocks: chapter.blocks, voice: voice)
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // A single Kokoro/ANE vocoder failure must not fail the whole
                        // book. Retry once with a fresh engine (resets ANE state);
                        // if it still fails, skip this chapter and keep going so the
                        // rest of the book still renders.
                        logger.error(
                            "Narration chapter \(n + 1) failed (\(error.localizedDescription, privacy: .public)); retrying with a fresh engine."
                        )
                        service = makeService()
                        do {
                            try await service.renderChapter(
                                chapterIndex: chapter.index, chapterNumber: chapter.displayNumber,
                                blocks: chapter.blocks, voice: voice)
                        } catch is CancellationError {
                            throw CancellationError()
                        } catch {
                            logger.error(
                                "Narration chapter \(n + 1) failed again; skipping. \(error.localizedDescription, privacy: .public)"
                            )
                            skipped += 1
                        }
                    }
                }
                if skipped > 0 {
                    progress(
                        .transcribing, 0.97,
                        "Narrated — \(skipped) chapter(s) skipped (synthesis failed).")
                }
                self?.refresh()
                return
            }

            // Resolve the security-scoped bookmark for restart-safe file access.
            // A resolved bookmark does NOT auto-start access — we must start it,
            // check the Bool, and always balance the stop via defer.
            var stale = false
            let url = try URL(
                resolvingBookmarkData: record.sourceBookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &stale)
            if stale {
                // A stale bookmark still resolves to a valid URL for this run;
                // it only signals that it should be recreated for future use.
                // Processing continues — we do not abort on staleness.
                logger.warning(
                    "Bookmark stale for \(record.displayName, privacy: .public); continuing this run"
                )
            }
            guard url.startAccessingSecurityScopedResource() else {
                throw BatchProcessingError.cannotAccessFile(url.lastPathComponent)
            }
            defer { url.stopAccessingSecurityScopedResource() }

            // Resolve the companion EPUB. When a companion bookmark was captured
            // at enqueue time (folder scope was live), resolve it and start its
            // OWN security scope — the audio file's bookmark does not cover the
            // sibling EPUB, so under the sandbox the import's EPUB read fails
            // without this. Old queue rows (pre-companion-bookmark) and same-run
            // re-enqueues fall back to the directory scan, which works when the
            // audio file's scope already grants the parent directory.
            let epubURL: URL
            var companionAccessToStop: URL?
            if let companionBookmark = record.companionBookmark {
                var companionStale = false
                let resolved = try URL(
                    resolvingBookmarkData: companionBookmark,
                    options: .withSecurityScope,
                    relativeTo: nil,
                    bookmarkDataIsStale: &companionStale)
                guard resolved.startAccessingSecurityScopedResource() else {
                    throw BatchProcessingError.cannotAccessFile(resolved.lastPathComponent)
                }
                companionAccessToStop = resolved
                epubURL = resolved
                if companionStale {
                    // Recreate the bookmark for future runs while access is live
                    // (a stale bookmark still resolves to a valid URL for this
                    // run). Recreation while access is active is what lets the new
                    // bookmark carry scope; failure is non-fatal — we just warn.
                    if let fresh = try? resolved.bookmarkData(
                        options: .withSecurityScope,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil), let id = record.id
                    {
                        try? self?.dao.updateCompanionBookmark(id: id, bookmark: fresh)
                    }
                    logger.warning(
                        "Companion bookmark stale for \(record.displayName, privacy: .public); continuing this run"
                    )
                }
            } else if let scanned = self?.companionEPUB(for: url) {
                epubURL = scanned
            } else {
                // Fail fast if there is no EPUB companion to align against.
                throw BatchProcessingError.noCompanion(url.lastPathComponent)
            }
            defer { companionAccessToStop?.stopAccessingSecurityScopedResource() }

            let audiobookID = url.deletingLastPathComponent().absoluteString

            // 1) Import: persist EPUB blocks for the book so the reader can show
            //    it. Reuses the existing import path (chapters + duration parsed
            //    from the audio file). `importBook` throws if zero blocks were
            //    persisted (a swallowed copy/extract failure), so the runner
            //    marks the item .failed instead of completing an empty book.
            progress(.importing, 0.05, "Importing…")
            try await self?.importBook(
                audioURL: url, epubURL: epubURL, audiobookID: audiobookID,
                dbService: dbService)

            // 2) Transcribe + 3) Align + 4) word timings. `MacAlignmentService`
            //    transcribes with WhisperKit, runs TokenDTW, writes anchors, then
            //    calls `recalculateTimeline` — which materializes `word_timing`
            //    rows (Phase A). The two progress steps front the single call so
            //    the UI reflects the long-running transcription phase.
            progress(.transcribing, 0.33, "Transcribing…")
            progress(.aligning, 0.66, "Aligning…")
            try await alignmentService.align(
                audiobookID: audiobookID,
                audioURL: url,
                epubURL: epubURL,
                dbService: dbService)
            self?.refresh()
        })
    }

    // MARK: - Adapters

    /// Thin adapter around `EPUBImportCoordinator`: parses chapters + duration
    /// from the audio file, then persists the companion EPUB's blocks into the
    /// shared database under the directory-derived audiobook ID.
    ///
    /// `EPUBImportCoordinator.importEPUB` is non-throwing `Void`: it logs and
    /// returns on a copy/block-clear/extract failure rather than propagating it.
    /// A fire-and-forget import that failed would leave zero EPUB blocks, yet the
    /// runner would still mark the book `.completed`. So after awaiting the
    /// import we verify blocks were actually persisted and throw when none were,
    /// letting `BatchQueueRunner.drain` record the item as `.failed`.
    private func importBook(
        audioURL: URL, epubURL: URL, audiobookID: String, dbService: DatabaseService
    ) async throws {
        let folderURL = audioURL.deletingLastPathComponent()
        let asset = AVURLAsset(url: audioURL)
        let chapters = await ChapterService.parseChapters(from: asset)
        let duration = try? await asset.load(.duration).seconds

        await EPUBImportCoordinator.importEPUB(
            from: epubURL,
            to: folderURL,
            databaseService: dbService,
            chapters: chapters,
            duration: duration.flatMap { $0.isFinite ? $0 : nil })

        // Verify the import actually produced blocks. `importEPUB` keys off
        // `folderURL.absoluteString`, which equals `audiobookID` here.
        let blockCount = (try? EPubBlockDAO(db: dbService.writer).count(for: audiobookID)) ?? 0
        guard blockCount > 0 else {
            throw BatchProcessingError.emptyImport(audioURL.lastPathComponent)
        }
    }

    /// Imports a standalone EPUB's blocks (no audio) under `audiobookID`, reusing
    /// the same `EPUBImportCoordinator.importEPUB` path as the align flow but with
    /// no audio chapters/duration. The EPUB is imported in place (source == dest),
    /// so the same-folder copy is skipped. Throws if zero blocks were persisted (a
    /// swallowed extract/parse failure), so the runner marks the item `.failed`
    /// rather than completing an empty book.
    private func importEPUBOnly(
        epubURL: URL, audiobookID: String, dbService: DatabaseService
    ) async throws {
        // Create the parent `audiobook` row FIRST. `epub_block` has a NOT-NULL
        // FK to `audiobook` (ON DELETE CASCADE, Schema V5), and — unlike the
        // align path, where the player's folder-load persists it — nothing else
        // creates it for a text-only narrate item. Without it every block insert
        // fails the FK and the import silently yields zero blocks. INSERT-OR-
        // REPLACE via `save`, so it's idempotent across re-runs.
        try AudiobookDAO(db: dbService.writer).save(
            AudiobookRecord(
                id: audiobookID,
                title: epubURL.deletingPathExtension().lastPathComponent,
                author: nil,
                duration: 0,
                fileCount: 0,
                addedAt: Date().ISO8601Format()))

        // Import in place. Passing the EPUB file itself as the import target makes
        // the coordinator key blocks off the EPUB's own URL (`epubURL.absoluteString`),
        // so multiple EPUBs in one folder don't collide on a shared parent-dir id,
        // while the same-file copy is still skipped.
        await EPUBImportCoordinator.importEPUB(
            from: epubURL,
            to: epubURL,
            databaseService: dbService,
            chapters: [],
            duration: nil)
        let blockCount = (try? EPubBlockDAO(db: dbService.writer).count(for: audiobookID)) ?? 0
        guard blockCount > 0 else {
            throw BatchProcessingError.emptyImport(epubURL.lastPathComponent)
        }
    }

    /// Finds the EPUB companion living alongside `audioURL` (same directory).
    private func companionEPUB(for audioURL: URL) -> URL? {
        let dir = audioURL.deletingLastPathComponent()
        let siblings =
            (try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles)) ?? []
        return siblings.first { $0.pathExtension.lowercased() == "epub" }
    }

    enum BatchProcessingError: LocalizedError {
        case cannotAccessFile(String)
        case noCompanion(String)
        case emptyImport(String)

        var errorDescription: String? {
            switch self {
            case .cannotAccessFile(let name):
                return "Cannot access \(name) — security-scoped access denied."
            case .noCompanion(let name):
                return "No EPUB companion found alongside \(name)."
            case .emptyImport(let name):
                return "EPUB import produced no blocks for \(name) — the import failed."
            }
        }
    }
}
