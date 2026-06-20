// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation

/// Cross-platform, source-agnostic audiobook exporter. Concatenates an ordered
/// list of `ExportItem`s into a gapless `.m4b`, transcodes once via
/// `AVAssetExportSession` (AAC), and stamps real Nero (`chpl`) + QuickTime
/// (`chap`) chapter atoms via `ChapterMarkerWriter`. Generalised from the
/// iOS-only `NarrationExportService` so narrated and imported books share a spine.
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

            chapters.append(ChapterAtom(startTime: currentPosition.seconds, title: item.title))

            guard let assetTrack = try await asset.loadTracks(withMediaType: .audio).first
            else { continue }
            try audioTrack.insertTimeRange(range, of: assetTrack, at: currentPosition)
            currentPosition = CMTimeAdd(currentPosition, range.duration)
        }

        let tempM4A = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")

        guard
            let session = AVAssetExportSession(
                asset: composition, presetName: AVAssetExportPresetAppleM4A)
        else { throw ExportError.exportSessionFailed }
        session.outputURL = tempM4A
        session.outputFileType = .m4a

        await session.export()
        guard session.status == .completed else { throw ExportError.exportSessionFailed }

        // Phase 1: stamp chapter atoms (swift-audio-marker rebuilds the moov,
        // which strips any metadata set above on the export session).
        let writer = ChapterMarkerWriter()
        do {
            try await writer.writeChapters(chapters, to: tempM4A, outputURL: outputURL)
            try? FileManager.default.removeItem(at: tempM4A)
        } catch {
            throw ExportError.chapterAtomWriteFailed
        }

        // Phase 2 (only when metadata is supplied): re-export the chapter-stamped
        // file through a passthrough AVAssetExportSession to embed title/author/cover
        // art. The moov rebuild in Phase 1 would otherwise discard these atoms.
        if let metadata {
            try await embedMetadata(metadata, in: outputURL)
        }
    }

    /// Replaces `fileURL` in-place with a copy that carries the supplied metadata
    /// atoms. Uses a passthrough export (lossless for already-AAC content).
    private func embedMetadata(_ metadata: ExportMetadata, in fileURL: URL) async throws {
        let asset = AVURLAsset(url: fileURL)
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("m4b")
        guard
            let session = AVAssetExportSession(
                asset: asset, presetName: AVAssetExportPresetPassthrough)
        else { throw ExportError.exportSessionFailed }
        session.outputURL = temp
        session.outputFileType = .m4a
        session.metadata = metadata.assetMetadataItems()
        await session.export()
        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: temp)
            throw ExportError.exportSessionFailed
        }
        try? FileManager.default.removeItem(at: fileURL)
        try FileManager.default.moveItem(at: temp, to: fileURL)
    }
}
