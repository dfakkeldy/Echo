// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import CryptoKit
import Foundation
import UIKit

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

        var cover: Data? = nil
        let embeddedImage = await ArtworkCache.embeddedArtworkImage(for: first)
        let coverImage: UIImage?
        if let img = embeddedImage {
            coverImage = img
        } else {
            coverImage = await ArtworkCache.folderArtworkImage(near: first)
        }
        if let image = coverImage {
            cover = image.jpegData(compressionQuality: 0.8)
        }

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
}
