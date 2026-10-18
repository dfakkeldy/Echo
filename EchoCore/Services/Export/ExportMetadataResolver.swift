// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CoreGraphics
import Foundation
import GRDB
import ImageIO
import UniformTypeIdentifiers

/// Gathers `ExportMetadata` without any UIKit/AppKit dependency (compiles on
/// iOS + macOS). Title/author come from `AudiobookRecord`; cover art is resolved
/// the *same* way the app resolves a book's display cover, so the exported file
/// carries the artwork the user already sees in the library and on the lock
/// screen (see `resolveCoverArt`).
enum ExportMetadataResolver {
    static func resolve(
        audiobookID: String,
        fallbackTitle: String,
        firstSourceURL: URL?,
        databaseWriter: DatabaseWriter
    ) async -> ExportMetadata {
        let record = try? AudiobookDAO(db: databaseWriter).get(audiobookID)
        let title = (record?.title).flatMap { $0.isEmpty ? nil : $0 } ?? fallbackTitle
        let author = record?.author
        let cover = await resolveCoverArt(
            audiobookID: audiobookID,
            firstSourceURL: firstSourceURL,
            databaseWriter: databaseWriter)
        return ExportMetadata(title: title, author: author, coverArt: cover)
    }

    /// Resolves cover art by walking the same cascade the app uses to *show* a
    /// book's cover, so "whatever the source of the audio was" gets the matching
    /// artwork baked into the `.m4b`:
    ///
    ///   1. **Embedded artwork** in the first source file — an imported `.m4b`/
    ///      `.mp3` that carries its own `covr`/ID3-`APIC` atom.
    ///   2. If none, branch on the source:
    ///      * **narrated EPUB** → the EPUB's stored front-matter cover image
    ///        (the per-chapter narration cache files have no embedded artwork,
    ///        so the cover only ever lives in the book);
    ///      * **imported** → a `cover.*` sidecar sitting beside the source file
    ///        (mp3 folders and Audiobookshelf downloads keep the cover next to
    ///        the audio rather than inside it).
    ///
    /// Whatever is found is normalised to JPEG/PNG because `swift-audio-marker`
    /// only embeds those two formats — without this, a HEIC/WEBP/GIF cover would
    /// be silently dropped by `Artwork(data:)`.
    static func resolveCoverArt(
        audiobookID: String,
        firstSourceURL: URL?,
        databaseWriter: DatabaseWriter
    ) async -> Data? {
        var data: Data?
        if let firstSourceURL {
            data = await embeddedArtworkData(for: firstSourceURL)
        }
        if data == nil {
            if ExportSourceResolver.isNarrated(
                audiobookID: audiobookID, databaseWriter: databaseWriter)
            {
                data = epubCoverData(audiobookID: audiobookID, databaseWriter: databaseWriter)
            } else if let firstSourceURL {
                data = folderSidecarArtworkData(near: firstSourceURL)
            }
        }
        return data.flatMap(normalizedArtworkData)
    }

    /// Reads raw artwork `Data` from an asset's common metadata (cross-platform).
    static func embeddedArtworkData(for url: URL) async -> Data? {
        let didScope = url.startAccessingSecurityScopedResource()
        defer { if didScope { url.stopAccessingSecurityScopedResource() } }
        let asset = AVURLAsset(url: url)
        let metadata = (try? await asset.load(.commonMetadata)) ?? []
        for item in metadata where item.commonKey == .commonKeyArtwork {
            if let data = try? await item.load(.dataValue) { return data }
        }
        return nil
    }

    /// Raw bytes of the EPUB's cover image. The cover is declared in the EPUB's
    /// OPF (`<meta name="cover">` / `properties="cover-image"`), NOT as an inline
    /// content image — so resolve it from the book's EPUB first, matching the live
    /// reader/lock screen (`ArtworkCache`/`EpubCoverResolver`). Only when the EPUB
    /// is unreachable or declares no cover do we fall back to a front-matter inline
    /// image block (covers EPUBs that embed the cover as a content `<img>`). The
    /// fallback assets live in the app's own container, so no scoping is required.
    static func epubCoverData(audiobookID: String, databaseWriter: DatabaseWriter) -> Data? {
        if let opfCover = EpubCoverResolver.coverData(forAudiobookID: audiobookID) {
            return opfCover
        }
        let blocks = (try? EPubBlockDAO(db: databaseWriter).allBlocks(for: audiobookID)) ?? []
        let images = blocks.filter { $0.blockKind == EPubBlockRecord.Kind.image.rawValue }
        let frontMatter = images.filter(\.isFrontMatter)
        let candidates = (frontMatter.isEmpty ? images : frontMatter)
            .sorted { $0.sequenceIndex < $1.sequenceIndex }
        for block in candidates {
            guard let path = block.imagePath,
                FileManager.default.fileExists(atPath: path),
                let data = try? Data(contentsOf: URL(fileURLWithPath: path))
            else { continue }
            return data
        }
        return nil
    }

    /// Raw bytes of a `cover.*` (or, failing that, the first alphabetically
    /// sorted) image file in the folder containing an imported audiobook's
    /// source file — the same sidecar `ArtworkCache.folderArtworkImage` surfaces
    /// at runtime.
    static func folderSidecarArtworkData(near url: URL) -> Data? {
        let folder = url.deletingLastPathComponent()
        let didScope = folder.startAccessingSecurityScopedResource()
        defer { if didScope { folder.stopAccessingSecurityScopedResource() } }

        let imageExtensions: Set<String> = [
            "jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "bmp", "tiff",
        ]
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        let images = files.filter { imageExtensions.contains($0.pathExtension.lowercased()) }
        guard !images.isEmpty else { return nil }

        let preferred = images.first {
            $0.deletingPathExtension().lastPathComponent.lowercased() == "cover"
        }
        let selected =
            preferred
            ?? images.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                    == .orderedAscending
            }.first
        return selected.flatMap { try? Data(contentsOf: $0) }
    }

    /// `swift-audio-marker` embeds only JPEG and PNG. Pass those through byte-for
    /// byte (so an already-tagged cover round-trips untouched); transcode any
    /// other format to JPEG via ImageIO so HEIC/WEBP/GIF/TIFF covers still make
    /// it into the file instead of being silently discarded. Returns `nil` only
    /// if the bytes can't be decoded as an image at all.
    static func normalizedArtworkData(_ data: Data) -> Data? {
        if isJPEG(data) || isPNG(data) { return data }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.9]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private static func isJPEG(_ data: Data) -> Bool {
        guard data.count >= 3 else { return false }
        let start = data.startIndex
        return data[start] == 0xFF && data[start + 1] == 0xD8 && data[start + 2] == 0xFF
    }

    private static func isPNG(_ data: Data) -> Bool {
        Array(data.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    }
}
