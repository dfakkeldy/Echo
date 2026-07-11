// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation
import UIKit
import os.log

/// Stateless helper that fetches and processes audiobook artwork.
/// Does not own mutable state — PlayerModel remains the single source of truth.
struct ArtworkCache {

    /// Extracts embedded artwork from an audio file's AVAsset metadata.
    /// - Parameter url: The audio file URL.
    /// - Returns: A downsampled UIImage, or nil if no artwork is embedded.
    static func embeddedArtworkImage(for url: URL) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        let metadata = (try? await asset.load(.commonMetadata)) ?? []

        let maxPixelSize = 600
        for item in metadata where item.commonKey == .commonKeyArtwork {
            guard let data = try? await item.load(.dataValue) else { continue }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { continue }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ]
            if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            {
                return UIImage(cgImage: cgImage)
            }
        }

        return nil
    }

    /// Lists non-hidden regular files in a directory. Security-scoped access
    /// must already be active on the folder URL before calling this method;
    /// callers should use the start/stop pattern around their entire scan+load
    /// operation (see `folderArtworkImage`).
    /// - Parameter folderURL: The directory to enumerate.
    /// - Returns: An array of file URLs, or an empty array on failure.
    static func listFilesInFolder(_ folderURL: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
    }

    /// Requests iCloud download for a ubiquitous item if it is not yet local.
    static func ensureItemIsAvailable(url: URL) async {
        do {
            let values = try url.resourceValues(forKeys: [
                .isUbiquitousItemKey,
                .ubiquitousItemDownloadingStatusKey,
            ])
            guard values.isUbiquitousItem == true else { return }
            let status =
                values.ubiquitousItemDownloadingStatus ?? URLUbiquitousItemDownloadingStatus.current
            if status != URLUbiquitousItemDownloadingStatus.current {
                try FileManager.default.startDownloadingUbiquitousItem(at: url)
            }
        } catch {
            os_log(.error, "ensureItemIsAvailable error: %{private}@", error.localizedDescription)
        }
    }

    /// Downscales an image file for display, with security-scoped access.
    static func loadImageFile(at imageURL: URL) async -> UIImage? {
        await ensureItemIsAvailable(url: imageURL)

        let didStart = imageURL.startAccessingSecurityScopedResource()
        defer { if didStart { imageURL.stopAccessingSecurityScopedResource() } }

        let maxPixelSize = 600
        guard let source = CGImageSourceCreateWithURL(imageURL as CFURL, nil) else { return nil }
        let downsampleOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard
            let cgImage = CGImageSourceCreateThumbnailAtIndex(
                source, 0, downsampleOptions as CFDictionary)
        else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// Loads the OPF-declared cover from a standalone EPUB archive.
    static func epubCoverImage(for epubURL: URL) async -> UIImage? {
        await ensureItemIsAvailable(url: epubURL)

        let didStart = epubURL.startAccessingSecurityScopedResource()
        defer { if didStart { epubURL.stopAccessingSecurityScopedResource() } }

        guard let data = EpubCoverResolver.coverData(epubArchiveURL: epubURL),
            let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 600,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }
        return UIImage(cgImage: cgImage)
    }

    /// Scans the folder containing an audio file for cover artwork images.
    static func folderArtworkImage(near url: URL) async -> UIImage? {
        let folderURL = url.deletingLastPathComponent()
        let imageExtensions = ["jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "bmp", "tiff"]
        let imageExtensionSet = Set(imageExtensions)

        let didStart = folderURL.startAccessingSecurityScopedResource()
        defer { if didStart { folderURL.stopAccessingSecurityScopedResource() } }

        let files = listFilesInFolder(folderURL)
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
            if let selected, let image = await loadImageFile(at: selected) {
                return image
            }
        }

        for ext in imageExtensions {
            let candidate = folderURL.appendingPathComponent("cover").appendingPathExtension(ext)
            if let image = await loadImageFile(at: candidate) {
                return image
            }
        }
        return nil
    }

    /// In-memory cache for Watch transfer JPEG data, keyed by artwork version
    /// to avoid redundant JPEG encodes on each sync cycle.
    @MainActor private static var cachedWatchJPEG: (version: Int, data: Data)?

    /// Creates a high-resolution (400x400) JPEG thumbnail suitable for Watch transfer.
    static func makeWatchThumbnailData(from image: UIImage, version: Int? = nil) -> Data? {
        if let version, let cached = cachedWatchJPEG, cached.version == version {
            return cached.data
        }
        // Aspect-fit the cover into the 200pt square with an artwork-derived
        // background (see ThumbnailRenderer) so portrait covers reach the Watch
        // and widget un-squished. 200pt @2x = 400×400px JPEG, as before.
        let watchImage = ThumbnailRenderer.squareThumbnail(from: image, side: 200, scale: 2.0)
        let data = watchImage.jpegData(compressionQuality: ImageEncoding.watchTransferJPEGQuality)
        if let data, let version {
            cachedWatchJPEG = (version, data)
        }
        return data
    }

    /// Generates display (300pt square) and watch (400px square) thumbnails from
    /// a source image. Both preserve the cover's aspect ratio: the cover is
    /// aspect-fit and centred with an artwork-derived background filling the
    /// margins (see `ThumbnailRenderer`), so a portrait cover is never squished
    /// into a square before reaching Now Playing, the lock screen, or the Watch.
    /// - Parameters:
    ///   - sourceImage: The artwork to resize.
    ///   - displayScale: The screen scale factor for the display thumbnail.
    /// - Returns: Tuple of (displayImage, watchData).
    static func generateThumbnails(from sourceImage: UIImage, displayScale: CGFloat) -> (
        UIImage, Data?
    ) {
        let thumbnailImage = ThumbnailRenderer.squareThumbnail(
            from: sourceImage, side: 300, scale: displayScale)
        let watchData = makeWatchThumbnailData(from: sourceImage)
        return (thumbnailImage, watchData)
    }
}
