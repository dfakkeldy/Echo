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
        var preferredFileNamesByChapterIndex: [Int: Set<String>] = [:]
        if let databaseWriter {
            let tracks = try TrackDAO(db: databaseWriter).tracks(for: audiobookID)
            for track in tracks {
                guard let voice = track.narrationVoice else { continue }
                let fileName = URL(fileURLWithPath: track.filePath).lastPathComponent
                let chapterIndex =
                    NarrationFileNaming.segmentLocation(fromFileName: fileName)?.chapterIndex
                    ?? NarrationFileNaming.chapterIndex(fromFileName: fileName)
                    ?? track.sortOrder
                titlesByChapterIndex[chapterIndex] = track.title
                voiceByChapterIndex[chapterIndex] = VoiceID(voice)
                preferredFileNamesByChapterIndex[chapterIndex, default: []].insert(fileName)
            }
        }
        // Collapse stale chapter renders while preserving segment-only chapters:
        // a full chapter file remains authoritative for its chapter, so stray or
        // partial segment caches can't shadow a complete chapter export.
        let deduped = Self.currentVersionFiles(
            files: files,
            audiobookID: audiobookID,
            voiceByChapterIndex: voiceByChapterIndex,
            preferredFileNamesByChapterIndex: preferredFileNamesByChapterIndex)
        return Self.orderedItems(files: deduped, titlesByChapterIndex: titlesByChapterIndex)
    }

    /// Reduces the globbed chapter files to at most one per chapter index, so a
    /// book re-rendered after a voice change or a `renderVersion` bump exports each
    /// chapter once, not twice (CODE_AUDIT §5.12). Prefers the canonical file — the
    /// current render version with the voice the DB recorded for that chapter — and
    /// falls back to a single deterministic file when that exact file isn't on disk,
    /// so a not-yet-re-rendered chapter is still exported rather than dropped.
    nonisolated static func currentVersionFiles(
        files: [URL],
        audiobookID: String,
        voiceByChapterIndex: [Int: VoiceID],
        preferredFileNamesByChapterIndex: [Int: Set<String>] = [:]
    ) -> [URL] {
        var filesByChapterIndex: [Int: [URL]] = [:]
        for url in files {
            guard let index = Self.chapterLocation(for: url)?.chapterIndex
            else { continue }
            filesByChapterIndex[index, default: []].append(url)
        }
        return filesByChapterIndex.flatMap { index, group in
            let chapterFiles = group.filter {
                NarrationFileNaming.segmentLocation(fromFileName: $0.lastPathComponent) == nil
            }
            if !chapterFiles.isEmpty {
                return Self.currentChapterFile(
                    files: chapterFiles,
                    audiobookID: audiobookID,
                    chapterIndex: index,
                    voice: voiceByChapterIndex[index],
                    preferredFileNames: preferredFileNamesByChapterIndex[index] ?? []
                ).map { [$0] } ?? []
            }
            return Self.currentSegmentFiles(
                files: group,
                voice: voiceByChapterIndex[index],
                preferredFileNames: preferredFileNamesByChapterIndex[index] ?? [])
        }.sorted(by: Self.isOrderedBefore)
    }

    /// Pure ordering+titling, unit-tested without generating audio. Files are
    /// re-sorted by the numeric chapter index embedded in each name (`-ch{N}-`);
    /// titles are looked up by that recovered index (== the narration track's
    /// `sortOrder`), never by file position, which diverges from chapter 10 on.
    /// A file whose index can't be recovered sorts last and gets a 1-based label.
    nonisolated static func orderedItems(
        files: [URL],
        titlesByChapterIndex: [Int: String]
    ) -> [ExportItem] {
        let sorted = files.sorted(by: Self.isOrderedBefore)
        var markedChapterIndices: Set<Int> = []
        return sorted.enumerated().map { position, fileURL in
            let chapterIndex = Self.chapterLocation(for: fileURL)?.chapterIndex
            let title =
                chapterIndex.flatMap { titlesByChapterIndex[$0] } ?? "Chapter \(position + 1)"
            let emitsMarker = chapterIndex.map { markedChapterIndices.insert($0).inserted } ?? true
            return ExportItem(
                title: title, url: fileURL, timeRange: nil, emitsChapterMarker: emitsMarker)
        }
    }

    private nonisolated static func currentChapterFile(
        files: [URL],
        audiobookID: String,
        chapterIndex: Int,
        voice: VoiceID?,
        preferredFileNames: Set<String>
    ) -> URL? {
        if let match = files.first(where: { preferredFileNames.contains($0.lastPathComponent) }) {
            return match
        }
        if let voice {
            let canonical = NarrationFileNaming.chapterFileName(
                audiobookID: audiobookID, chapterIndex: chapterIndex, voice: voice)
            if let match = files.first(where: { $0.lastPathComponent == canonical }) {
                return match
            }
        }
        return files.min { $0.lastPathComponent < $1.lastPathComponent }
    }

    private nonisolated static func currentSegmentFiles(
        files: [URL],
        voice: VoiceID?,
        preferredFileNames: Set<String>
    ) -> [URL] {
        let segmentFiles = files.filter {
            NarrationFileNaming.segmentLocation(fromFileName: $0.lastPathComponent) != nil
        }
        let preferred = segmentFiles.filter { preferredFileNames.contains($0.lastPathComponent) }
        if !preferred.isEmpty {
            return preferred.sorted(by: Self.isOrderedBefore)
        }
        if let voice {
            let suffix = "-\(voice.rawValue)-v\(NarrationFileNaming.renderVersion).m4a"
            let canonical = segmentFiles.filter { $0.lastPathComponent.hasSuffix(suffix) }
            if !canonical.isEmpty {
                return canonical.sorted(by: Self.isOrderedBefore)
            }
        }
        let currentSuffix = "-v\(NarrationFileNaming.renderVersion).m4a"
        let currentVersion = segmentFiles.filter { $0.lastPathComponent.hasSuffix(currentSuffix) }
        return (currentVersion.isEmpty ? segmentFiles : currentVersion).sorted(
            by: Self.isOrderedBefore)
    }

    private nonisolated static func chapterLocation(for url: URL) -> (
        chapterIndex: Int,
        segmentIndex: Int?
    )? {
        let fileName = url.lastPathComponent
        if let segment = NarrationFileNaming.segmentLocation(fromFileName: fileName) {
            return (segment.chapterIndex, segment.segmentIndex)
        }
        guard let chapterIndex = NarrationFileNaming.chapterIndex(fromFileName: fileName) else {
            return nil
        }
        return (chapterIndex, nil)
    }

    private nonisolated static func isOrderedBefore(_ lhs: URL, _ rhs: URL) -> Bool {
        let lhsLocation = Self.chapterLocation(for: lhs)
        let rhsLocation = Self.chapterLocation(for: rhs)
        switch (lhsLocation, rhsLocation) {
        case (let lhsInfo?, let rhsInfo?):
            if lhsInfo.chapterIndex != rhsInfo.chapterIndex {
                return lhsInfo.chapterIndex < rhsInfo.chapterIndex
            }
            switch (lhsInfo.segmentIndex, rhsInfo.segmentIndex) {
            case (let lhsSegment?, let rhsSegment?):
                return lhsSegment < rhsSegment
            case (nil, _?):
                return true
            case (_?, nil):
                return false
            case (nil, nil):
                return lhs.lastPathComponent < rhs.lastPathComponent
            }
        case (nil, _?):
            return false
        case (_?, nil):
            return true
        case (nil, nil):
            return lhs.lastPathComponent < rhs.lastPathComponent
        }
    }
}
