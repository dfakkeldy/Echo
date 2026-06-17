// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

#if os(iOS)
    import AudioMarker
#endif

/// One chapter boundary for the exported m4b.
struct ChapterAtom {
    let startTime: Double
    let title: String
}

#if os(iOS)
    // The `swift-audio-marker` package both *is* a module named `AudioMarker`
    // **and** exports an empty `public struct AudioMarker` namespace. That struct
    // shadows the module name, so `AudioMarker.Chapter` / `AudioMarker.ChapterList`
    // (the plan's suggested qualification) won't compile — the compiler treats
    // them as members of the empty struct. Meanwhile the package's `Chapter`
    // collides with Echo's own `Chapter` model (`Models/Chapter.swift`), so an
    // unqualified `Chapter` is ambiguous. We sidestep both by reaching the
    // package types through `ChapterList` (unambiguous — only the package defines
    // it) and its `Element` (the package's `Chapter`).
    private typealias PackageChapterList = ChapterList
    private typealias PackageChapter = ChapterList.Element
#endif

/// Writes real Nero (`chpl`) + QuickTime (`chap`) chapter atoms via the
/// `swift-audio-marker` package. Replaces the former copy-only stub.
struct ChapterMarkerWriter {
    enum WriteError: Error { case unavailableOnPlatform }

    /// Copies `sourceURL` → `outputURL`, then writes chapter atoms in place.
    ///
    /// `swift-audio-marker`'s `writeChapters` is synchronous; this method stays
    /// `async` so the call site in the `NarrationExportService` actor reads
    /// uniformly and so future package versions can become `async` without a
    /// signature change.
    func writeChapters(_ chapters: [ChapterAtom], to sourceURL: URL, outputURL: URL) async throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: outputURL)
        #if os(iOS)
            let engine = AudioMarkerEngine()
            let list = PackageChapterList(
                chapters.map { atom in
                    PackageChapter(start: .seconds(atom.startTime), title: atom.title)
                })
            try engine.writeChapters(list, to: outputURL)
        #else
            throw WriteError.unavailableOnPlatform
        #endif
    }
}
