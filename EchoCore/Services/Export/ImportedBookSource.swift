// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation
import GRDB

/// `ExportSource` for an already-imported audiobook (m4b or loose mp3/m4a), read
/// from its original on-disk files (referenced, never copied). Two shapes:
///   • one source file with N chapters → N items slicing it by chapter time range;
///   • multiple track files → one whole-file item per file, titled by the
///     positionally-matching chapter (or the track's own title).
/// Multi-file books with sub-file chapters collapse to per-file granularity (a
/// documented v1 limitation — the common case is one chapter per file).
struct ImportedBookSource: ExportSource {
    enum SourceError: Error { case sourceUnavailable }

    let audiobookID: String
    let databaseWriter: DatabaseWriter

    func items() async throws -> [ExportItem] {
        let tracks = try TrackDAO(db: databaseWriter).tracks(for: audiobookID)
        let chapters = try ChapterDAO(db: databaseWriter).chapters(for: audiobookID)
        let items = Self.makeItems(tracks: tracks, chapters: chapters)
        guard !items.isEmpty else { throw SourceError.sourceUnavailable }
        for item in items
        where !FileManager.default.fileExists(atPath: item.url.path(percentEncoded: false)) {
            throw SourceError.sourceUnavailable
        }
        return items
    }

    /// Pure mapping (no disk/DB) from records to ordered export items.
    static func makeItems(tracks: [TrackRecord], chapters: [ChapterRecord]) -> [ExportItem] {
        let enabledTracks = tracks.filter(\.isEnabled).sorted { $0.sortOrder < $1.sortOrder }
        let enabledChapters = chapters.filter(\.isEnabled).sorted { $0.sortOrder < $1.sortOrder }

        if enabledTracks.count == 1, enabledChapters.count >= 1,
            let url = URL(string: enabledTracks[0].filePath)
        {
            return enabledChapters.map { ch in
                ExportItem(
                    title: ch.title,
                    url: url,
                    timeRange: CMTimeRange(
                        start: CMTime(seconds: ch.startSeconds, preferredTimescale: 600),
                        duration: CMTime(
                            seconds: max(0, ch.endSeconds - ch.startSeconds),
                            preferredTimescale: 600)))
            }
        }

        return enabledTracks.enumerated().compactMap { index, track in
            guard let url = URL(string: track.filePath) else { return nil }
            let title =
                enabledChapters.count == enabledTracks.count
                ? enabledChapters[index].title
                : track.title
            return ExportItem(title: title, url: url, timeRange: nil)
        }
    }
}
