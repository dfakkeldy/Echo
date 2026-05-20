import Foundation
import os.log

/// Manages EPUB asset storage under Application Support/EPUBAssets/.
///
/// All image paths stored in the database must be real local file paths
/// usable by `UIImage(contentsOfFile:)`. Raw EPUB hrefs are never stored
/// in `timeline_item.image_path` or `epub_block.image_path`.
struct EPUBAssetStorage {
    private let logger = Logger(subsystem: "com.orbitaudiobooks", category: "EPUBAssets")
    private let fileManager = FileManager.default
    let databaseService: DatabaseService?

    init(databaseService: DatabaseService? = nil) {
        self.databaseService = databaseService
    }

    /// The root directory for EPUB assets.
    var rootDirectory: URL {
        guard let appSupport = fileManager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first else {
            fatalError("Application Support directory not available")
        }
        return appSupport.appendingPathComponent("EPUBAssets", isDirectory: true)
    }

    /// The asset directory for a specific audiobook.
    func directory(for audiobookID: String) -> URL {
        let safeName = SafeFileName.fromAudiobookID(audiobookID)
        return rootDirectory.appendingPathComponent(safeName, isDirectory: true)
    }

    /// Creates the asset directory for the given audiobook if it doesn't exist.
    func prepare(for audiobookID: String) throws {
        let dir = directory(for: audiobookID)
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

        let dir = directory(for: audiobookID)
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
        let dir = directory(for: audiobookID)
        guard fileManager.fileExists(atPath: dir.path) else { return }
        try fileManager.removeItem(at: dir)
    }

    /// Checks if an image exists at the given local path.
    func imageExists(at path: String) -> Bool {
        fileManager.fileExists(atPath: path)
    }
}
