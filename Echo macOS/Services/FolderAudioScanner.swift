// SPDX-License-Identifier: GPL-3.0-or-later
//
//  FolderAudioScanner.swift
//  Echo macOS
//
//  Recursively scans a user-picked folder for audiobook files and enqueues each
//  (with its companion EPUB) into the persistent batch queue. Extracted from the
//  former `MacBulkAlignmentService` when the inline "Bulk Align Folder…" flow was
//  replaced by the DB-backed batch queue (plan 2026-06-16, Task C4) — only the
//  scan + enqueue survived; the old in-memory progress state machine and its
//  `MacBulkAlignmentProgressView` were removed.
//

import Foundation

enum FolderAudioScanner {
    /// Scans `folderURL` and enqueues every discovered audio file into the
    /// persistent batch queue. Files with no EPUB companion are still enqueued and
    /// surface as failed during processing (with a clear error) rather than being
    /// silently dropped.
    ///
    /// The companion EPUB (if any) is located **here**, while `folderURL`'s
    /// security scope from the NSOpenPanel is still active, so `enqueue` can
    /// bookmark it. The sandboxed app cannot read the sibling EPUB at processing
    /// time otherwise: the audio file's own bookmark does not cover it.
    @MainActor
    static func enqueueFolder(_ folderURL: URL, into service: MacBatchProcessingService) throws {
        let didStart = folderURL.startAccessingSecurityScopedResource()
        defer { if didStart { folderURL.stopAccessingSecurityScopedResource() } }
        for audioURL in scanForAudioFiles(in: folderURL) {
            try service.enqueue(
                fileURL: audioURL, companionEPUB: companionEPUB(for: audioURL))
        }
    }

    /// Finds the EPUB companion living alongside `audioURL` (same directory).
    static func companionEPUB(for audioURL: URL) -> URL? {
        let dir = audioURL.deletingLastPathComponent()
        let siblings =
            (try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles)) ?? []
        return siblings.first { $0.pathExtension.lowercased() == "epub" }
    }

    /// Recursively enumerates audio files in `folder`, respecting standard
    /// hidden-file and package exclusions.
    static func scanForAudioFiles(in folder: URL) -> [URL] {
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
}
