// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Centralized directory access for the app group, documents, caches,
/// and application support.  Use these instead of ad-hoc
/// `FileManager.default.urls(for:in:)` calls scattered across the codebase.
enum FileLocations {

    enum Error: Swift.Error, LocalizedError {
        case appGroupNotFound(String)

        var errorDescription: String? {
            switch self {
            case .appGroupNotFound(let identifier):
                return
                    "App Group container not found for identifier: \(identifier). Check entitlements."
            }
        }
    }

    /// The shared App Group container directory.
    static func appGroupContainer(identifier: String = "group.com.echo.audiobooks") throws -> URL {
        guard
            let url = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: identifier
            )
        else {
            throw Error.appGroupNotFound(identifier)
        }
        return url
    }

    static var documentsDirectory: URL {
        URL.documentsDirectory
    }

    static var cachesDirectory: URL {
        URL.cachesDirectory
    }

    static var applicationSupportDirectory: URL {
        URL.applicationSupportDirectory
    }

    /// Directory for unpacked EPUB content inside the caches folder.
    static func epubUnpackedDirectory(safeID: String) -> URL {
        cachesDirectory
            .appending(path: "EPUBUnpacked", directoryHint: .isDirectory)
            .appending(path: safeID, directoryHint: .isDirectory)
    }

    /// Managed folder for an Audiobookshelf-downloaded item's files (audio + any EPUB):
    /// `Application Support/ABSLibrary/<remoteItemID>/`. Once populated and handed to
    /// `PlayerLoadingCoordinator.loadFolder`, this folder IS the book's identity — so an
    /// ABS book becomes indistinguishable from a local import and every study feature works.
    /// ABS item IDs are server UUIDs (filesystem-safe), used verbatim.
    static func absLibraryDirectory(remoteItemID: String) -> URL {
        absLibraryRootDirectory
            .appending(path: remoteItemID, directoryHint: .isDirectory)
    }

    static var absLibraryRootDirectory: URL {
        applicationSupportDirectory
            .appending(path: "ABSLibrary", directoryHint: .isDirectory)
    }

    static func absImportStagingDirectory(remoteItemID: String, id: UUID = UUID()) -> URL {
        absLibraryRootDirectory
            .appending(
                path: ".\(remoteItemID)-staging-\(id.uuidString)",
                directoryHint: .isDirectory)
    }

    /// Cache directory for cover images extracted during Library root rescans.
    static var libraryCoversDirectory: URL {
        cachesDirectory
            .appending(path: "LibraryCovers", directoryHint: .isDirectory)
    }
}
