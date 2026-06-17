// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation
import GRDB

/// Handles the export of generated narration (Phase 2).
/// Supports exporting raw AAC files per chapter, or combining into a single `.m4b` file.
actor NarrationExportService {

    enum ExportError: Error {
        case compositionFailed
        case exportSessionFailed
        case chapterAtomWriteFailed
        case missingAudiobook
    }

    /// Collects the per-chapter `.m4a` cache files for a book and returns them for sharing.
    /// This is the fast, free export path (7a).
    func exportChapterFiles(for bookID: String, cacheDirectory: URL) async throws -> [URL] {
        let fileManager = FileManager.default
        let prefix = NarrationFileNaming.chapterPrefix(audiobookID: bookID)

        let allFiles = try fileManager.contentsOfDirectory(
            at: cacheDirectory, includingPropertiesForKeys: nil)

        let bookFiles =
            allFiles
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "m4a" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        return bookFiles
    }

    /// Joins the chapter files into a single gapless `.m4b` (full
    /// `AVAssetExportSession` re-encode) and embeds real Nero (`chpl`) +
    /// QuickTime (`chap`) chapter-navigation markers via the `swift-audio-marker`
    /// package (see `ChapterMarkerWriter`). The audio is continuous and the
    /// chapter markers let a chapter-aware player jump between chapters.
    ///
    /// When `databaseWriter` is supplied, chapter titles are taken from the
    /// book's `TrackRecord`s (ordered by `sortOrder`); otherwise they fall back
    /// to `"Chapter N"`.
    func exportM4B(
        for bookID: String,
        bookTitle: String,
        cacheDirectory: URL,
        outputURL: URL,
        databaseWriter: DatabaseWriter? = nil
    )
        async throws
    {
        let chapterFiles = try await exportChapterFiles(for: bookID, cacheDirectory: cacheDirectory)
        guard !chapterFiles.isEmpty else { throw ExportError.missingAudiobook }

        // Real per-chapter titles, ordered to match the chapter-file order
        // (both are `sortOrder`-ascending). Index `i` → title for the i-th file.
        var trackTitles: [Int: String] = [:]
        if let databaseWriter {
            let tracks = try TrackDAO(db: databaseWriter).tracks(for: bookID)
            for (index, track) in tracks.enumerated() {
                trackTitles[index] = track.title
            }
        }

        let composition = AVMutableComposition()
        guard
            let audioTrack = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else {
            throw ExportError.compositionFailed
        }

        var currentPosition = CMTime.zero
        var chapters: [ChapterAtom] = []

        for (index, fileURL) in chapterFiles.enumerated() {
            let asset = AVURLAsset(url: fileURL)
            let duration = try await asset.load(.duration)

            // Add chapter metadata — use the rendered track's real title when available.
            let chapterName = trackTitles[index] ?? "Chapter \(index + 1)"
            chapters.append(ChapterAtom(startTime: currentPosition.seconds, title: chapterName))

            guard let assetTrack = try await asset.loadTracks(withMediaType: .audio).first else {
                continue
            }

            let timeRange = CMTimeRange(start: .zero, duration: duration)
            try audioTrack.insertTimeRange(timeRange, of: assetTrack, at: currentPosition)

            currentPosition = CMTimeAdd(currentPosition, duration)
        }

        // Export to M4A first
        let tempM4A = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString
        ).appendingPathExtension("m4a")

        guard
            let exportSession = AVAssetExportSession(
                asset: composition, presetName: AVAssetExportPresetAppleM4A)
        else {
            throw ExportError.exportSessionFailed
        }
        exportSession.outputURL = tempM4A
        exportSession.outputFileType = .m4a

        await exportSession.export()

        guard exportSession.status == .completed else {
            throw ExportError.exportSessionFailed
        }

        // Inject chapters to make it an M4B
        let writer = ChapterMarkerWriter()
        do {
            try await writer.writeChapters(chapters, to: tempM4A, outputURL: outputURL)
            // Cleanup temp
            try? FileManager.default.removeItem(at: tempM4A)
        } catch {
            throw ExportError.chapterAtomWriteFailed
        }
    }
}
