// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A book discovered under a Library root: the folder that directly holds its
/// audio, its audio files, and a companion EPUB if one sits beside them.
struct DiscoveredBook: Equatable {
    let folderURL: URL
    let audioFiles: [URL]
    let companionEPUB: URL?
}

/// Recursively finds books under a root by grouping audio files by their parent
/// folder. One folder containing audio == one book (a lone `.m4b`'s folder is its
/// book). Mirrors `FolderAudioScanner`'s enumerator options.
enum LibraryScanner {
    /// Shared with `EditionMatcher`, whose path-identity grouping must agree
    /// with the scanner on what counts as an audio file. `nonisolated`: read
    /// from nonisolated grouping code and the `@concurrent` cover extractor.
    nonisolated static let audioExtensions: Set<String> = [
        "m4b", "mp3", "m4a", "aax", "wav", "flac",
    ]
    private nonisolated static let imageExtensions = [
        "jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "bmp", "tiff",
    ]
    private nonisolated static let imageExtensionSet = Set(imageExtensions)

    static func discoverBooks(in root: URL) -> [DiscoveredBook] {
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])

        var audioByFolder: [URL: [URL]] = [:]
        while let url = enumerator?.nextObject() as? URL {
            guard audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let folder = url.deletingLastPathComponent().standardizedFileURL
            audioByFolder[folder, default: []].append(url)
        }

        return audioByFolder.keys.sorted { $0.path < $1.path }.map { folder in
            DiscoveredBook(
                folderURL: folder,
                audioFiles: audioByFolder[folder]!.sorted { $0.path < $1.path },
                companionEPUB: companionEPUB(in: folder))
        }
    }

    private static func companionEPUB(in folder: URL) -> URL? {
        let siblings =
            (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return siblings.first { $0.pathExtension.lowercased() == "epub" }
    }
}

extension LibraryScanner {
    struct ScannedMetadata: Equatable {
        var title: String
        var author: String?
        var narrator: String?
        var duration: TimeInterval
        var coverImageData: Data?
    }

    static func fallbackTitle(for book: DiscoveredBook) -> String {
        book.folderURL.lastPathComponent
    }

    /// Cheap per-book metadata read for the shelf — title/author/duration/cover
    /// only. No chapter parsing, EPUB extraction, or alignment (those run on first
    /// open). Falls back to the folder name when audio carries no title.
    static func readMetadata(for book: DiscoveredBook) async -> ScannedMetadata {
        guard let first = book.audioFiles.first else {
            return ScannedMetadata(
                title: fallbackTitle(for: book), author: nil, narrator: nil,
                duration: 0, coverImageData: nil)
        }
        let asset = AVURLAsset(url: first)
        let metadata = (try? await asset.load(.commonMetadata)) ?? []

        let trackTitle = await stringValue(in: metadata, key: .commonKeyTitle)
        let albumTitle = await stringValue(in: metadata, key: .commonKeyAlbumName)
        let author = await stringValue(in: metadata, key: .commonKeyArtist)
        let duration =
            ((try? await asset.load(.duration))?.seconds).flatMap {
                $0.isFinite ? $0 : nil
            } ?? 0

        let cover = await coverArtworkJPEGData(for: first)

        return ScannedMetadata(
            title: resolveBookTitle(
                album: albumTitle,
                track: trackTitle,
                fallback: fallbackTitle(for: book)),
            author: author, narrator: nil, duration: duration, coverImageData: cover)
    }

    static func resolveBookTitle(album: String?, track: String?, fallback: String) -> String {
        if let album = album?.trimmingCharacters(in: .whitespacesAndNewlines), !album.isEmpty {
            return album
        }
        if let track = track?.trimmingCharacters(in: .whitespacesAndNewlines), !track.isEmpty {
            return track
        }
        return fallback
    }

    private static func stringValue(
        in metadata: [AVMetadataItem], key: AVMetadataKey
    ) async -> String? {
        guard let item = metadata.first(where: { $0.commonKey?.rawValue == key.rawValue })
        else { return nil }
        return try? await item.load(.stringValue)
    }

    /// Cover for an already-persisted shelf row. `bookURL` is the row id's
    /// URL — the book's folder, or the audio file itself for a directly
    /// opened book. Same source priority as `readMetadata`: embedded artwork
    /// of the (first) audio file, then a sidecar image beside it.
    /// `@concurrent` so the shelf-load enrichment's AVAsset metadata read and
    /// thumbnail decode run on the global executor, not the main actor.
    @concurrent
    static func coverJPEGData(forBookURL bookURL: URL) async -> Data? {
        let audioURL: URL?
        if audioExtensions.contains(bookURL.pathExtension.lowercased()) {
            audioURL = bookURL
        } else {
            audioURL = firstAudioFile(in: bookURL)
        }
        guard let audioURL else { return nil }
        return await coverArtworkJPEGData(for: audioURL)
    }

    private nonisolated static func firstAudioFile(in folder: URL) -> URL? {
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )) ?? []
        return
            files
            .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.path < $1.path }
            .first
    }

    private nonisolated static func coverArtworkJPEGData(for audioURL: URL) async -> Data? {
        if let embedded = await embeddedArtworkJPEGData(for: audioURL) {
            return embedded
        }
        return await folderArtworkJPEGData(near: audioURL)
    }

    private nonisolated static func embeddedArtworkJPEGData(for url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        let metadata = (try? await asset.load(.commonMetadata)) ?? []

        for item in metadata where item.commonKey == .commonKeyArtwork {
            guard let data = try? await item.load(.dataValue),
                let jpegData = jpegData(fromImageData: data)
            else { continue }
            return jpegData
        }

        return nil
    }

    private nonisolated static func folderArtworkJPEGData(near url: URL) async -> Data? {
        let folderURL = url.deletingLastPathComponent()
        let didStart = folderURL.startAccessingSecurityScopedResource()
        defer { if didStart { folderURL.stopAccessingSecurityScopedResource() } }

        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: folderURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )) ?? []

        let images = files.filter { fileURL in
            imageExtensionSet.contains(fileURL.pathExtension.lowercased())
        }

        if !images.isEmpty {
            let preferred = images.first { fileURL in
                fileURL.deletingPathExtension().lastPathComponent.lowercased() == "cover"
            }
            let selected =
                preferred
                ?? images.sorted {
                    $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent)
                        == .orderedAscending
                }.first

            if let selected,
                let data = await jpegData(fromImageFile: selected)
            {
                return data
            }
        }

        for ext in imageExtensions {
            let candidate = folderURL.appendingPathComponent("cover").appendingPathExtension(ext)
            if let data = await jpegData(fromImageFile: candidate) {
                return data
            }
        }

        return nil
    }

    private nonisolated static func jpegData(fromImageFile imageURL: URL) async -> Data? {
        await ensureItemIsAvailable(url: imageURL)

        let didStart = imageURL.startAccessingSecurityScopedResource()
        defer { if didStart { imageURL.stopAccessingSecurityScopedResource() } }

        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil) else { return nil }
        return jpegData(from: source)
    }

    private nonisolated static func ensureItemIsAvailable(url: URL) async {
        guard
            let values = try? url.resourceValues(forKeys: [
                .isUbiquitousItemKey,
                .ubiquitousItemDownloadingStatusKey,
            ]),
            values.isUbiquitousItem == true
        else { return }

        let status = values.ubiquitousItemDownloadingStatus ?? .current
        if status != .current {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
    }

    private nonisolated static func jpegData(fromImageData data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return jpegData(from: source)
    }

    private nonisolated static func jpegData(from source: CGImageSource) -> Data? {
        let maxPixelSize = 600
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard
            let cgImage = CGImageSourceCreateThumbnailAtIndex(
                source, 0, thumbnailOptions as CFDictionary)
        else { return nil }

        let output = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                output,
                UTType.jpeg.identifier as CFString,
                1,
                nil
            )
        else { return nil }

        let destinationOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.8
        ]
        CGImageDestinationAddImage(destination, cgImage, destinationOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
