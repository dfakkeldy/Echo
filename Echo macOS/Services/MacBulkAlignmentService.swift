// SPDX-License-Identifier: GPL-3.0-or-later
//
//  MacBulkAlignmentService.swift
//  Echo macOS
//
//  WS-12: Bulk folder alignment for overnight alignment of entire libraries.
//  Scans a folder recursively for audio files, finds matching EPUB/PDF
//  companions, and runs MacAlignmentService (shared TokenDTW pipeline) on
//  each pair. Anchors are written to the shared database so timeline
//  recalculation + auto-scroll work immediately.
//

import Foundation
import Observation
import os.log

@MainActor
@Observable
final class MacBulkAlignmentService {
    var progress = BulkAlignmentProgress()

    private var currentTask: Task<Void, Never>?
    private let logger = Logger(category: "MacBulkAlignment")

    struct BulkAlignmentProgress {
        var totalBooks = 0
        var completedBooks = 0
        var currentBookName = ""
        var currentChapter = 0
        var totalChapters = 0
        var isRunning = false
        var estimatedTimeRemaining: TimeInterval?
        var sleepWhenDone = false
    }

    private let alignmentService = MacAlignmentService()

    // MARK: - Public API

    /// Begins bulk alignment of all audiobooks found under `folderURL`.
    func start(folderURL: URL, dbService: DatabaseService) async {
        progress.isRunning = true
        currentTask = Task { [weak self] in
            guard let self else { return }

            // 1. Recursively scan for audio files
            let audioFiles = scanForAudioFiles(in: folderURL)
            await MainActor.run { self.progress.totalBooks = audioFiles.count }

            let startDate = Date()

            // 2. For each audio file, find matching EPUB/PDF and align
            for (i, audioURL) in audioFiles.enumerated() {
                guard !Task.isCancelled else { break }

                await MainActor.run {
                    self.progress.currentBookName = audioURL.lastPathComponent
                    self.progress.completedBooks = i
                }

                // Find matching companion document in same directory
                let dir = audioURL.deletingLastPathComponent()
                let fm = FileManager.default
                let siblings =
                    (try? fm.contentsOfDirectory(
                        at: dir,
                        includingPropertiesForKeys: nil,
                        options: .skipsHiddenFiles
                    )) ?? []

                let epub = siblings.first { $0.pathExtension.lowercased() == "epub" }
                let pdf = siblings.first { $0.pathExtension.lowercased() == "pdf" }

                do {
                    // Mirror the iOS audiobook identifier (`folderURL.absoluteString`)
                    // so the shared block-ID formula matches the importer's.
                    let audiobookID = dir.absoluteString
                    if let epub {
                        logger.debug(
                            "Aligning \(audioURL.lastPathComponent) with EPUB \(epub.lastPathComponent)"
                        )
                        try await alignmentService.align(
                            audiobookID: audiobookID, audioURL: audioURL, epubURL: epub,
                            dbService: dbService)
                    } else if let pdf {
                        // PDF text extraction is not implemented; this call fails the
                        // container.xml check and is skipped (logged below).
                        logger.debug(
                            "Aligning \(audioURL.lastPathComponent) with PDF \(pdf.lastPathComponent)"
                        )
                        try await alignmentService.align(
                            audiobookID: audiobookID, audioURL: audioURL, epubURL: pdf,
                            dbService: dbService)
                    } else {
                        logger.debug(
                            "Skipping \(audioURL.lastPathComponent): no EPUB or PDF found in directory"
                        )
                        continue
                    }
                } catch {
                    logger.error(
                        "Alignment failed for \(audioURL.lastPathComponent): \(error.localizedDescription)"
                    )
                    // Continue with next book rather than aborting the entire batch
                }

                // Update ETA based on elapsed time and remaining books
                let elapsed = Date().timeIntervalSince(startDate)
                let completed = i + 1
                if completed > 0 {
                    let perBook = elapsed / Double(completed)
                    let remaining = Double(audioFiles.count - completed) * perBook
                    await MainActor.run {
                        self.progress.estimatedTimeRemaining = remaining
                    }
                }
            }

            await MainActor.run {
                self.progress.completedBooks = audioFiles.count
                self.progress.isRunning = false
                self.progress.estimatedTimeRemaining = nil
                if self.progress.sleepWhenDone {
                    self.sleepMac()
                }
            }
        }
    }

    /// Cancels the current bulk alignment run.
    func stop() {
        currentTask?.cancel()
        progress.isRunning = false
        progress.estimatedTimeRemaining = nil
    }

    /// Scans `folderURL` and enqueues every discovered audio file into the
    /// persistent batch queue. Reuses the existing recursive scan logic so the
    /// only behavioral change is "enqueue" instead of "align inline". Files with
    /// no EPUB companion are still enqueued and surface as failed during
    /// processing (with a clear error) rather than being silently dropped.
    func enqueueFolder(_ folderURL: URL, into service: MacBatchProcessingService) throws {
        for audioURL in scanForAudioFiles(in: folderURL) {
            try service.enqueue(fileURL: audioURL)
        }
    }

    // MARK: - Scanning

    /// Recursively enumerates audio files in `folder`, respecting standard
    /// hidden-file and package exclusions.
    private func scanForAudioFiles(in folder: URL) -> [URL] {
        let audioExtensions = Set(["m4b", "mp3", "m4a", "aax", "wav", "flac"])
        var results: [URL] = []

        let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )

        while let url = enumerator?.nextObject() as? URL {
            if audioExtensions.contains(url.pathExtension.lowercased()) {
                results.append(url)
            }
        }

        return results.sorted { $0.path < $1.path }
    }

    // MARK: - System Sleep

    /// Triggers macOS system sleep via pmset.
    private nonisolated func sleepMac() {
        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            process.arguments = ["sleepnow"]
            try process.run()
        } catch {
            Logger(category: "MacBulkAlignment").error(
                "Failed to trigger sleep: \(error.localizedDescription)")
        }
    }
}
