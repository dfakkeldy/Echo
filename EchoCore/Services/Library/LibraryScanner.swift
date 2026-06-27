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
    private static let audioExtensions: Set<String> = ["m4b", "mp3", "m4a", "aax", "wav", "flac"]
    private static let imageExtensions = [
        "jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "bmp", "tiff"
    ]
    private static let imageExtensionSet = Set(imageExtensions)

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

        let title = await stringValue(in: metadata, key: .commonKeyTitle)
        let author = await stringValue(in: metadata, key: .commonKeyArtist)
        let duration =
            ((try? await asset.load(.duration))?.seconds).flatMap {
                $0.isFinite ? $0 : nil
            } ?? 0

        let cover = await coverArtworkJPEGData(for: first)

        return ScannedMetadata(
            title: title?.isEmpty == false ? title! : fallbackTitle(for: book),
            author: author, narrator: nil, duration: duration, coverImageData: cover)
    }

    private static func stringValue(
        in metadata: [AVMetadataItem], key: AVMetadataKey
    ) async -> String? {
        guard let item = metadata.first(where: { $0.commonKey?.rawValue == key.rawValue })
        else { return nil }
        return try? await item.load(.stringValue)
    }

    private static func coverArtworkJPEGData(for audioURL: URL) async -> Data? {
        if let embedded = await embeddedArtworkJPEGData(for: audioURL) {
            return embedded
        }
        return await folderArtworkJPEGData(near: audioURL)
    }

    private static func embeddedArtworkJPEGData(for url: URL) async -> Data? {
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

    private static func folderArtworkJPEGData(near url: URL) async -> Data? {
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
            let selected = preferred ?? images.sorted {
                $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
            }.first

            if let selected,
               let data = await jpegData(fromImageFile: selected) {
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

    private static func jpegData(fromImageFile imageURL: URL) async -> Data? {
        await ensureItemIsAvailable(url: imageURL)

        let didStart = imageURL.startAccessingSecurityScopedResource()
        defer { if didStart { imageURL.stopAccessingSecurityScopedResource() } }

        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil) else { return nil }
        return jpegData(from: source)
    }

    private static func ensureItemIsAvailable(url: URL) async {
        guard let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey
        ]),
            values.isUbiquitousItem == true
        else { return }

        let status = values.ubiquitousItemDownloadingStatus ?? .current
        if status != .current {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        }
    }

    private static func jpegData(fromImageData data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return jpegData(from: source)
    }

    private static func jpegData(from source: CGImageSource) -> Data? {
        let maxPixelSize = 600
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source, 0, thumbnailOptions as CFDictionary)
        else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return nil }

        let destinationOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.8
        ]
        CGImageDestinationAddImage(destination, cgImage, destinationOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
