// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

#if canImport(AudioMarker)
    import AudioMarker
#endif

/// One chapter boundary for the exported m4b.
struct ChapterAtom {
    let startTime: Double
    let title: String
}

#if canImport(AudioMarker)
    // `swift-audio-marker` exports an empty `public struct AudioMarker` that
    // shadows its own module name, and a `Chapter` that collides with Echo's
    // `Models/Chapter.swift`. Reach the package types through `ChapterList`
    // (unambiguous — only the package defines it) and its `Element`.
    private typealias PackageChapterList = ChapterList
    private typealias PackageChapter = ChapterList.Element
#endif

/// Writes real Nero (`chpl`) + QuickTime (`chap`) chapter atoms via the
/// `swift-audio-marker` package. Replaces the former copy-only stub.
struct ChapterMarkerWriter {
    enum WriteError: Error { case unavailableOnPlatform }

    /// Copies `sourceURL` → `outputURL`, then writes chapter atoms (and, when
    /// supplied, book-level title/author/cover-art tags) in place.
    ///
    /// Both chapters and metadata are written through the package's own
    /// single in-place `modify` pass — deliberately *not* via a later
    /// `AVAssetExportSession`, which rebuilds the MP4 container and strips the
    /// chapter atoms (verified by `roundTripPreservesChaptersAndTitle`). The
    /// package's reader doesn't surface AVFoundation's `commonIdentifierTitle`
    /// atom across its rewrite, so the metadata must travel on the package's own
    /// `AudioMetadata` model rather than being pre-stamped on the export session.
    ///
    /// `swift-audio-marker`'s write is synchronous; this method stays `async` so
    /// the call site in the export actor reads uniformly and so future package
    /// versions can become `async` without a signature change.
    func writeChapters(
        _ chapters: [ChapterAtom],
        to sourceURL: URL,
        outputURL: URL,
        metadata: ExportMetadata? = nil
    ) async throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: outputURL)
        #if canImport(AudioMarker)
            let engine = AudioMarkerEngine()
            // Read whatever the composed file already carries, then layer the
            // chapters (and optional book tags) onto it and write once. This is
            // the package's metadata-preserving in-place rewrite — no container
            // rebuild, so the chapter atoms survive into the final output.
            var info = (try? engine.read(from: outputURL)) ?? AudioFileInfo()
            info.chapters = PackageChapterList(
                chapters.map { atom in
                    PackageChapter(start: .seconds(atom.startTime), title: atom.title)
                })
            if let metadata {
                info.metadata.title = metadata.title
                if let author = metadata.author, !author.isEmpty {
                    info.metadata.artist = author
                }
                if let coverArt = metadata.coverArt {
                    info.metadata.artwork = try? Artwork(data: coverArt)
                }
            }
            try engine.modify(info, in: outputURL)
        #else
            throw WriteError.unavailableOnPlatform
        #endif
    }
}
