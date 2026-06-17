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
    /// book's narration `TrackRecord`s (matched by `sortOrder`); otherwise they
    /// fall back to `"Chapter N"`.
    func exportM4B(
        for bookID: String,
        bookTitle: String,
        cacheDirectory: URL,
        outputURL: URL,
        databaseWriter: DatabaseWriter? = nil
    )
        async throws
    {
        let unsortedFiles = try await exportChapterFiles(
            for: bookID, cacheDirectory: cacheDirectory)
        guard !unsortedFiles.isEmpty else { throw ExportError.missingAudiobook }

        // Real per-chapter titles keyed by the *chapter index*, not file position.
        // A narration track's `sortOrder` is the same chapter index the cache
        // filename embeds (`NarrationService` writes `sortOrder: chapterIndex`),
        // so titles are looked up by that index — never by enumerated position,
        // which diverges from the file order at chapter 10+. Only synthesized
        // tracks (`narrationVoice != nil`) are rendered to `.m4a`, so non-narration
        // and disabled rows are excluded to keep the count and keys aligned.
        var titlesByChapterIndex: [Int: String] = [:]
        if let databaseWriter {
            let tracks = try TrackDAO(db: databaseWriter).tracks(for: bookID)
            for track in tracks where track.narrationVoice != nil {
                titlesByChapterIndex[track.sortOrder] = track.title
            }
        }

        // Order the files by their numeric chapter index and pair each with its
        // title in one pure step (see `Self.orderedChapters`), so the audio and
        // the chapter markers can't drift apart.
        let plan = Self.orderedChapters(
            files: unsortedFiles, titlesByChapterIndex: titlesByChapterIndex)

        let composition = AVMutableComposition()
        guard
            let audioTrack = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else {
            throw ExportError.compositionFailed
        }

        var currentPosition = CMTime.zero
        var chapters: [ChapterAtom] = []

        for entry in plan {
            let asset = AVURLAsset(url: entry.fileURL)
            let duration = try await asset.load(.duration)

            chapters.append(
                ChapterAtom(startTime: currentPosition.seconds, title: entry.title))

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

    /// One ordered chapter file paired with the title to stamp on its marker.
    struct PlannedChapter: Equatable {
        let fileURL: URL
        let title: String
    }

    /// Pure ordering+titling step, factored out of `exportM4B` so it can be unit
    /// tested without generating audio.
    ///
    /// `exportChapterFiles` returns files sorted *lexicographically* by name, which
    /// interleaves double-digit chapters (ch0, ch1, ch10, ch11, ch2…). Both the
    /// concatenated audio and the chapter markers must follow the true chapter
    /// order, so files are re-sorted by the numeric index embedded in each name
    /// (`-ch{N}-`). Titles are then looked up by that recovered index — which equals
    /// the narration track's `sortOrder` — never by file position, which diverges
    /// from chapter 10 onward. A file whose index can't be recovered sorts last and
    /// falls back to a 1-based positional label.
    nonisolated static func orderedChapters(
        files: [URL], titlesByChapterIndex: [Int: String]
    ) -> [PlannedChapter] {
        let sorted = files.sorted { lhs, rhs in
            let l = NarrationFileNaming.chapterIndex(fromFileName: lhs.lastPathComponent)
            let r = NarrationFileNaming.chapterIndex(fromFileName: rhs.lastPathComponent)
            switch (l, r) {
            case (let l?, let r?): return l < r
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return lhs.lastPathComponent < rhs.lastPathComponent
            }
        }
        return sorted.enumerated().map { position, fileURL in
            let chapterIndex = NarrationFileNaming.chapterIndex(
                fromFileName: fileURL.lastPathComponent)
            let title =
                chapterIndex.flatMap { titlesByChapterIndex[$0] } ?? "Chapter \(position + 1)"
            return PlannedChapter(fileURL: fileURL, title: title)
        }
    }
}
