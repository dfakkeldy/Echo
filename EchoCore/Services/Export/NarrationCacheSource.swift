// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

/// `ExportSource` for a narrated book: the per-chapter `.m4a` files the narration
/// pipeline cached. Ordering + titling is ported verbatim from the former
/// `NarrationExportService.orderedChapters`, including the >=10-chapter numeric
/// sort fix (a lexicographic name sort interleaves ch1, ch10, ch11, ch2…).
struct NarrationCacheSource: ExportSource {
    let audiobookID: String
    let cacheDirectory: URL
    let databaseWriter: DatabaseWriter?

    func items() async throws -> [ExportItem] {
        let fm = FileManager.default
        let prefix = NarrationFileNaming.chapterPrefix(audiobookID: audiobookID)
        let files =
            ((try? fm.contentsOfDirectory(at: cacheDirectory, includingPropertiesForKeys: nil))
            ?? [])
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "m4a" }

        var titlesByChapterIndex: [Int: String] = [:]
        if let databaseWriter {
            let tracks = try TrackDAO(db: databaseWriter).tracks(for: audiobookID)
            for track in tracks where track.narrationVoice != nil {
                titlesByChapterIndex[track.sortOrder] = track.title
            }
        }
        return Self.orderedItems(files: files, titlesByChapterIndex: titlesByChapterIndex)
    }

    /// Pure ordering+titling, unit-tested without generating audio. Files are
    /// re-sorted by the numeric chapter index embedded in each name (`-ch{N}-`);
    /// titles are looked up by that recovered index (== the narration track's
    /// `sortOrder`), never by file position, which diverges from chapter 10 on.
    /// A file whose index can't be recovered sorts last and gets a 1-based label.
    static func orderedItems(files: [URL], titlesByChapterIndex: [Int: String]) -> [ExportItem] {
        let sorted = files.sorted { lhs, rhs in
            let l = NarrationFileNaming.chapterIndex(fromFileName: lhs.lastPathComponent)
            let r = NarrationFileNaming.chapterIndex(fromFileName: rhs.lastPathComponent)
            switch (l, r) {
            case (let l?, let r?): return l < r
            case (nil, _?): return false
            case (_?, nil): return true
            case (nil, nil): return lhs.lastPathComponent < rhs.lastPathComponent
            }
        }
        return sorted.enumerated().map { position, fileURL in
            let chapterIndex = NarrationFileNaming.chapterIndex(
                fromFileName: fileURL.lastPathComponent)
            let title =
                chapterIndex.flatMap { titlesByChapterIndex[$0] } ?? "Chapter \(position + 1)"
            return ExportItem(title: title, url: fileURL, timeRange: nil)
        }
    }
}
