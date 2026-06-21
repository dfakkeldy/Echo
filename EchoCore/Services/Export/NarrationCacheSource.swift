// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

/// `ExportSource` for a narrated book: the per-chapter `.m4a` files the narration
/// pipeline cached. Ordering + titling preserves the >=10-chapter numeric sort
/// fix (a lexicographic name sort interleaves ch1, ch10, ch11, ch2…).
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
        var voiceByChapterIndex: [Int: VoiceID] = [:]
        if let databaseWriter {
            let tracks = try TrackDAO(db: databaseWriter).tracks(for: audiobookID)
            for track in tracks {
                guard let voice = track.narrationVoice else { continue }
                titlesByChapterIndex[track.sortOrder] = track.title
                voiceByChapterIndex[track.sortOrder] = VoiceID(voice)
            }
        }
        // Collapse to one file per chapter before ordering: a re-render after a
        // voice change or a renderVersion bump leaves two files for the same
        // chapter index, and globbing every `-ch*.m4a` would export both (§5.12).
        let deduped = Self.currentVersionFiles(
            files: files, audiobookID: audiobookID, voiceByChapterIndex: voiceByChapterIndex)
        return Self.orderedItems(files: deduped, titlesByChapterIndex: titlesByChapterIndex)
    }

    /// Reduces the globbed chapter files to at most one per chapter index, so a
    /// book re-rendered after a voice change or a `renderVersion` bump exports each
    /// chapter once, not twice (CODE_AUDIT §5.12). Prefers the canonical file — the
    /// current render version with the voice the DB recorded for that chapter — and
    /// falls back to a single deterministic file when that exact file isn't on disk,
    /// so a not-yet-re-rendered chapter is still exported rather than dropped.
    static func currentVersionFiles(
        files: [URL], audiobookID: String, voiceByChapterIndex: [Int: VoiceID]
    ) -> [URL] {
        var filesByChapterIndex: [Int: [URL]] = [:]
        for url in files {
            guard let index = NarrationFileNaming.chapterIndex(fromFileName: url.lastPathComponent)
            else { continue }
            filesByChapterIndex[index, default: []].append(url)
        }
        return filesByChapterIndex.compactMap { index, group in
            if let voice = voiceByChapterIndex[index] {
                let canonical = NarrationFileNaming.chapterFileName(
                    audiobookID: audiobookID, chapterIndex: index, voice: voice)
                if let match = group.first(where: { $0.lastPathComponent == canonical }) {
                    return match
                }
            }
            return group.min { $0.lastPathComponent < $1.lastPathComponent }
        }
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
