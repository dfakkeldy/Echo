// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation
import GRDB

/// Gathers `ExportMetadata` without any UIKit/AppKit dependency (compiles on
/// iOS + macOS). Title/author come from `AudiobookRecord`; cover art is pulled
/// best-effort from the first source file's embedded artwork (imported books
/// usually carry one; narrated cache files do not → cover stays nil and the
/// prompt step in Task 9 offers to add one).
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
        var cover: Data?
        if let firstSourceURL { cover = await embeddedArtworkData(for: firstSourceURL) }
        return ExportMetadata(title: title, author: author, coverArt: cover)
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
}
