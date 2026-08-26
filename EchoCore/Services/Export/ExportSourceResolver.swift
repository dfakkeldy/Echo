// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

/// Picks the right `ExportSource` for a book. A matching anthology build receipt
/// owns source identity even before its first narration track exists; otherwise
/// synthesized tracks select the narrated cache and imported tracks select the
/// originals.
enum ExportSourceResolver {
    static func isNarrated(audiobookID: String, databaseWriter: DatabaseWriter) -> Bool {
        let tracks = (try? TrackDAO(db: databaseWriter).tracks(for: audiobookID)) ?? []
        return tracks.contains { $0.narrationVoice != nil }
    }

    static func resolve(
        audiobookID: String,
        databaseWriter: DatabaseWriter,
        cacheDirectory: URL,
        preferredVoice: VoiceID
    ) -> ExportSource {
        if usesNarrationCache(audiobookID: audiobookID, databaseWriter: databaseWriter) {
            return NarrationCacheSource(
                audiobookID: audiobookID, cacheDirectory: cacheDirectory,
                databaseWriter: databaseWriter, preferredVoice: preferredVoice)
        }
        return ImportedBookSource(audiobookID: audiobookID, databaseWriter: databaseWriter)
    }

    static func usesNarrationCache(
        audiobookID: String,
        databaseWriter: DatabaseWriter
    ) -> Bool {
        let hasAnthologyReceipt =
            (try? AnthologyNarrationManifestResolver(db: databaseWriter).hasMatchingReceipt(
                audiobookID: audiobookID)) ?? false
        return hasAnthologyReceipt
            || isNarrated(audiobookID: audiobookID, databaseWriter: databaseWriter)
    }
}
