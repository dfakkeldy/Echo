// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

/// Picks the right `ExportSource` for a book by inspecting its tracks: any
/// synthesized track (`narrationVoice != nil`) ⇒ narrated cache; otherwise the
/// imported originals.
enum ExportSourceResolver {
    static func isNarrated(audiobookID: String, databaseWriter: DatabaseWriter) -> Bool {
        let tracks = (try? TrackDAO(db: databaseWriter).tracks(for: audiobookID)) ?? []
        return tracks.contains { $0.narrationVoice != nil }
    }

    static func resolve(
        audiobookID: String,
        databaseWriter: DatabaseWriter,
        cacheDirectory: URL
    ) -> ExportSource {
        if isNarrated(audiobookID: audiobookID, databaseWriter: databaseWriter) {
            return NarrationCacheSource(
                audiobookID: audiobookID, cacheDirectory: cacheDirectory,
                databaseWriter: databaseWriter)
        }
        return ImportedBookSource(audiobookID: audiobookID, databaseWriter: databaseWriter)
    }
}
