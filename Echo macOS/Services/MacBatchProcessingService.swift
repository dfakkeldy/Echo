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
    private let dao: BatchQueueDAO
    private let alignmentService = MacAlignmentService()
    private let logger = Logger(category: "MacBatchProcessing")

    private(set) var items: [BatchQueueRecord] = []
    private(set) var isProcessing = false
    private var runner: BatchQueueRunner?

    init(dbService: DatabaseService) {
        self.dbService = dbService
        self.dao = BatchQueueDAO(db: dbService.writer)
    }

    /// Call once at launch: reset interrupted items, then resume.
    func resumeOnLaunch() {
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
    func enqueue(fileURL: URL) throws {
        let bookmark = try fileURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil)
        // Key off the source directory so blocks/anchors/word-timings written
        // during processing match the importer's `folderURL.absoluteString`.
        let audiobookID = fileURL.deletingLastPathComponent().absoluteString
        _ = try dao.enqueue(
            BatchQueueRecord(
                audiobookID: audiobookID,
                sourceBookmark: bookmark,
                displayName: fileURL.deletingPathExtension().lastPathComponent,
                queuePosition: 0,
                status: .queued,
                progress: 0,
                enqueuedAt: ISO8601DateFormatter().string(from: Date())))
        refresh()
        start()
    }

    /// Starts draining the queue if not already running.
    func start() {
        guard runner == nil else { return }
        let runner = BatchQueueRunner(dao: dao, stages: makeStages())
        self.runner = runner
        Task { [weak self] in
            self?.isProcessing = true
            await runner.drain()
            self?.isProcessing = false
            self?.runner = nil
            self?.refresh()
        }
    }

    func refresh() { items = (try? dao.allItems()) ?? [] }
    func clearCompleted() {
        try? dao.deleteCompleted()
        refresh()
    }

    // MARK: - Stages

    private func makeStages() -> BatchQueueRunner.Stages {
        let dbService = self.dbService
        let alignmentService = self.alignmentService
        let logger = self.logger
        return .init(run: { [weak self] record, progress in
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

            // Fail fast if there is no EPUB companion to align against.
            guard let epubURL = self?.companionEPUB(for: url) else {
                throw BatchProcessingError.noCompanion(url.lastPathComponent)
            }
            let audiobookID = url.deletingLastPathComponent().absoluteString

            // 1) Import: persist EPUB blocks for the book so the reader can show
            //    it. Reuses the existing import path (chapters + duration parsed
            //    from the audio file).
            progress(.importing, 0.05, "Importing…")
            await self?.importBook(
                audioURL: url, epubURL: epubURL, dbService: dbService)

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
    private func importBook(
        audioURL: URL, epubURL: URL, dbService: DatabaseService
    ) async {
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

        var errorDescription: String? {
            switch self {
            case .cannotAccessFile(let name):
                return "Cannot access \(name) — security-scoped access denied."
            case .noCompanion(let name):
                return "No EPUB companion found alongside \(name)."
            }
        }
    }
}
