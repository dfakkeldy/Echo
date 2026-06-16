// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import os.log

enum EPUBAssetError: LocalizedError {
    case rootUnavailable
    var errorDescription: String? {
        "Application Support directory not available"
    }
}

/// Manages EPUB asset storage under Application Support/EPUBAssets/.
///
/// All image paths stored in the database must be real local file paths
/// usable by `UIImage(contentsOfFile:)`. Raw EPUB hrefs are never stored
/// in `timeline_item.image_path` or `epub_block.image_path`.
struct EPUBAssetStorage {
    private let logger = Logger(category: "EPUBAssets")
    private let fileManager = FileManager.default
    let databaseService: DatabaseService?

    init(databaseService: DatabaseService? = nil) {
        self.databaseService = databaseService
    }

    /// The root directory for EPUB assets, or nil if Application Support is unavailable.
    var rootDirectory: URL? {
        guard let appSupport = fileManager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else {
            logger.error("Application Support directory not available")
            return nil
        }
        return appSupport.appendingPathComponent("EPUBAssets", isDirectory: true)
    }

    /// The asset directory for a specific audiobook, or nil if root is unavailable.
    func directory(for audiobookID: String) -> URL? {
        guard let root = rootDirectory else { return nil }
        let safeName = SafeFileName.fromAudiobookID(audiobookID)
        return root.appendingPathComponent(safeName, isDirectory: true)
    }

    /// Creates the asset directory for the given audiobook if it doesn't exist.
    func prepare(for audiobookID: String) throws {
        guard let dir = directory(for: audiobookID) else {
            throw EPUBAssetError.rootUnavailable
        }
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Copies an image from the EPUB source to local asset storage.
    ///
    /// - Parameters:
    ///   - sourceURL: The image's original location (inside the EPUB).
    ///   - audiobookID: The audiobook owning this image.
    ///   - filename: The image filename for the copy.
    ///
    /// - Returns: The local file path usable by `UIImage(contentsOfFile:)`, or `nil` on failure.
    func copyImage(from sourceURL: URL, audiobookID: String, filename: String) -> String? {
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            logger.warning("Image source not found: \(sourceURL.path)")
            return nil
        }

        guard let dir = directory(for: audiobookID) else {
            logger.error("Cannot copy image: root directory unavailable")
            return nil
        }
        let safeFilename = filename.replacingOccurrences(of: "/", with: "_")
        let destinationURL = dir.appendingPathComponent(safeFilename)

        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            logger.debug("Copied image: \(safeFilename) → \(destinationURL.path)")
            return destinationURL.path
        } catch {
            logger.error("Failed to copy image \(safeFilename): \(error.localizedDescription)")
            return nil
        }
    }

    /// Removes all assets for an audiobook.
    func removeAll(for audiobookID: String) throws {
        guard let dir = directory(for: audiobookID) else {
            throw EPUBAssetError.rootUnavailable
        }
        guard fileManager.fileExists(atPath: dir.path) else { return }
        try fileManager.removeItem(at: dir)
    }

    /// Checks if an image exists at the given local path.
    func imageExists(at path: String) -> Bool {
        fileManager.fileExists(atPath: path)
    }
}
