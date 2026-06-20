// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation
import GRDB

/// Thin compatibility shim over `AudioExportService` + `NarrationCacheSource`,
/// kept so the existing iOS call site (`ExportProgressView`) stays unchanged
/// until it migrates to the unified resolver (Task 8). New code should use
/// `AudioExportService` + an `ExportSource` directly.
actor NarrationExportService {
    enum ExportError: Error {
        case compositionFailed
        case exportSessionFailed
        case chapterAtomWriteFailed
        case missingAudiobook
    }

    /// Collects the per-chapter `.m4a` cache files for a book (fast/free path).
    func exportChapterFiles(for bookID: String, cacheDirectory: URL) async throws -> [URL] {
        let fileManager = FileManager.default
        let prefix = NarrationFileNaming.chapterPrefix(audiobookID: bookID)
        let allFiles = try fileManager.contentsOfDirectory(
            at: cacheDirectory, includingPropertiesForKeys: nil)
        return
            allFiles
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "m4a" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Concatenates the cached chapters into a single chaptered `.m4b`. Delegates
    /// to `AudioExportService` via `NarrationCacheSource`.
    func exportM4B(
        for bookID: String,
        bookTitle: String,
        cacheDirectory: URL,
        outputURL: URL,
        databaseWriter: DatabaseWriter? = nil
    ) async throws {
        let source = NarrationCacheSource(
            audiobookID: bookID, cacheDirectory: cacheDirectory, databaseWriter: databaseWriter)
        let items = try await source.items()
        guard !items.isEmpty else { throw ExportError.missingAudiobook }
        try await AudioExportService().exportM4B(items: items, outputURL: outputURL)
    }
}
