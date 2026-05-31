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
                return "App Group container not found for identifier: \(identifier). Check entitlements."
            }
        }
    }

    /// The shared App Group container directory.
    static func appGroupContainer(identifier: String = "group.com.orbitaudiobooks") throws -> URL {
        guard let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: identifier
        ) else {
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
}
