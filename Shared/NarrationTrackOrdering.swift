// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Orders a book's `TrackRecord` rows into the playable file-URL list the macOS
/// player loads for a narrated book: enabled tracks only, ascending `sortOrder`
/// (which equals the rendered chapter index), mapped to file URLs. Pure so it's
/// unit-testable without a player or AVFoundation.
enum NarrationTrackOrdering {
    static func orderedFileURLs(_ tracks: [TrackRecord]) -> [URL] {
        tracks
            .filter { $0.isEnabled }
            .sorted { $0.sortOrder < $1.sortOrder }
            .map { URL(fileURLWithPath: $0.filePath) }
    }
}
