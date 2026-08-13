// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation

/// Cross-platform, source-agnostic audiobook exporter. Concatenates an ordered
/// list of `ExportItem`s into a gapless `.m4b`, transcodes once via
/// `AVAssetExportSession` (AAC), and stamps real Nero (`chpl`) + QuickTime
/// (`chap`) chapter atoms via `ChapterMarkerWriter`. Narrated and imported books
/// share this one spine.
actor AudioExportService {
    enum ExportError: Error {
        case noChapters
        case compositionFailed
        case exportSessionFailed
        case chapterAtomWriteFailed
    }

    func exportM4B(items: [ExportItem], outputURL: URL, metadata: ExportMetadata? = nil)
        async throws
    {
        guard !items.isEmpty else { throw ExportError.noChapters }

        // Imported originals live behind security-scoped bookmarks; the files must
        // stay accessible through the *entire* export (AVAssetExportSession reads
        // them after this loop), so scope every distinct source URL up front and
        // release only when the whole function exits. For narration cache files
        // (app-owned) startAccessing returns false → harmless no-op.
        let urls = Set(items.map(\.url))
        var scoped: [URL] = []
        for url in urls where url.startAccessingSecurityScopedResource() { scoped.append(url) }
        defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() } }

        let composition = AVMutableComposition()
        guard
            let audioTrack = composition.addMutableTrack(
                withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        else { throw ExportError.compositionFailed }

        var currentPosition = CMTime.zero
        var chapters: [ChapterAtom] = []

        for item in items {
            let asset = AVURLAsset(url: item.url)
            let fullDuration = try await asset.load(.duration)
            let range = item.timeRange ?? CMTimeRange(start: .zero, duration: fullDuration)

            guard let assetTrack = try await asset.loadTracks(withMediaType: .audio).first
            else { continue }
            try audioTrack.insertTimeRange(range, of: assetTrack, at: currentPosition)
            if item.emitsChapterMarker {
                chapters.append(ChapterAtom(startTime: currentPosition.seconds, title: item.title))
            }
            currentPosition = CMTimeAdd(currentPosition, range.duration)
        }

        let tempM4A = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        defer { try? FileManager.default.removeItem(at: tempM4A) }

        guard
            let session = AVAssetExportSession(
                asset: composition, presetName: AVAssetExportPresetAppleM4A)
        else { throw ExportError.exportSessionFailed }
        do {
            try await session.export(to: tempM4A, as: .m4a)
        } catch {
            throw ExportError.exportSessionFailed
        }

        // Single, container-preserving finishing pass: `ChapterMarkerWriter` stamps
        // the chapter atoms AND (when supplied) the title/author/cover-art tags
        // through `swift-audio-marker`'s in-place `modify`. Doing both in the
        // package's own write — rather than re-exporting through AVFoundation to add
        // metadata — is what keeps the chapter atoms alive: any `AVAssetExportSession`
        // run *after* the atoms exist rebuilds the MP4 container and silently drops
        // them. The chaptered audiobook is the core feature, so chapters are written
        // last and nothing rebuilds the container afterwards (verified by
        // `roundTripPreservesChaptersAndTitle`).
        // `tempM4A` is cleaned up by the `defer` above on every exit path.
        let writer = ChapterMarkerWriter()
        do {
            try await writer.writeChapters(
                chapters, to: tempM4A, outputURL: outputURL, metadata: metadata)
        } catch {
            throw ExportError.chapterAtomWriteFailed
        }
    }
}
