// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

#if canImport(AudioMarker)
    import AudioMarker
#endif

/// Re-stamps an already-rendered `.m4b` with real heading chapter titles, book tags,
/// cover art, and a version comment — WITHOUT re-encoding the audio. The audio and
/// the existing chapter *times* are preserved; only the chapter *titles* and the
/// book metadata are replaced. Used by `echo-cli retag` to fix m4bs produced before
/// the export was repaired.
enum M4BRetagger {

    enum RetagError: Error { case audioMarkerUnavailable, noChapters }

    /// Pairs the existing chapter start times with the EPUB heading titles, keeping
    /// the times. Count-tolerant: extra times fall back to `fallback[i]` (the m4b's
    /// own current title) and extra titles are dropped. Pure — unit-tested.
    static func chapterAtoms(
        times: [Double], newTitles: [String], fallback: [String]
    ) -> [ChapterAtom] {
        times.enumerated().map { index, start in
            let title =
                index < newTitles.count
                ? newTitles[index]
                : (index < fallback.count ? fallback[index] : "Chapter \(index + 1)")
            return ChapterAtom(startTime: start, title: title)
        }
    }

    /// Heading titles for EVERY chapter, in `chapterIndex` order — matching the order
    /// the m4b's chapters were written in (`HeadlessNarrationRunner` renders one
    /// chapter per `chapterIndex`, sorted by index). Excluded chapters are NOT
    /// filtered out: the m4b has a chapter for each one, so dropping them here would
    /// shift every later title onto the wrong chapter.
    static func chapterTitles(forExpandedEPUBAt dir: URL) async throws -> [String] {
        let db = try DatabaseService(inMemory: ())
        let audiobookID = "retag-\(dir.lastPathComponent)"
        try db.write { db in
            try db.execute(
                sql:
                    "INSERT INTO audiobook (id, title, duration, added_at) VALUES (?, '', 0, '2026-01-01T00:00:00Z')",
                arguments: [audiobookID])
        }
        let importer = EPUBImportService(assetStorage: EPUBAssetStorage(databaseService: db))
        let blocks = try await importer.import(
            audiobookID: audiobookID, epubURL: dir, chapters: [], bookDuration: nil)
        return NarrationOutlineBuilder.build(allBlocks: blocks, isRendered: { _ in true })
            .sorted { $0.chapterIndex < $1.chapterIndex }
            .map(\.title)
    }

    /// Reads `m4b`'s existing chapters (via the package reader — the stale m4bs are
    /// not AVFoundation-readable), re-titles them from the EPUB headings, embeds the
    /// tags/cover/comment, and writes the result to `out`. Audio is untouched.
    static func retag(
        m4b: URL, expandedEPUBDir: URL, out: URL,
        title: String, author: String?, comment: String
    ) async throws {
        #if canImport(AudioMarker)
            let engine = AudioMarkerEngine()
            let existing = (try? engine.read(from: m4b))?.chapters
            let times = (existing?.map { $0.start.timeInterval }) ?? []
            let fallback = (existing?.map(\.title)) ?? []
            guard !times.isEmpty else { throw RetagError.noChapters }

            let newTitles = (try? await chapterTitles(forExpandedEPUBAt: expandedEPUBDir)) ?? []
            let atoms = chapterAtoms(times: times, newTitles: newTitles, fallback: fallback)
            let cover = EpubCoverResolver.coverData(expandedEPUBDir: expandedEPUBDir)

            // Write to a temp file, then move over `out` — `ChapterMarkerWriter` copies
            // source→output before modifying, so writing in place (out == m4b) would
            // delete the source first. The temp hop makes in-place retag safe.
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString).appendingPathExtension("m4b")
            defer { try? FileManager.default.removeItem(at: temp) }
            try await ChapterMarkerWriter().writeChapters(
                atoms, to: m4b, outputURL: temp,
                metadata: ExportMetadata(
                    title: title, author: author, coverArt: cover, comment: comment))
            if FileManager.default.fileExists(atPath: out.path) {
                try FileManager.default.removeItem(at: out)
            }
            try FileManager.default.moveItem(at: temp, to: out)
        #else
            throw RetagError.audioMarkerUnavailable
        #endif
    }
}
