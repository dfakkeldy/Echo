// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Local stand-in for the `swift-audio-marker` package's chapter-writing surface.
///
/// **It does NOT write real chapter atoms.** It copies the source to the output
/// unchanged. Authoring Nero `chpl` / QuickTime `chap` chapter atoms on iOS
/// requires the `swift-audio-marker` SPM package (or manual mp4-atom surgery),
/// which is **deferred post-1.0** (finish-plan Phase 7, Option A). For 1.0, the
/// chaptered export is the per-chapter files (`NarrationExportService.exportChapterFiles`,
/// the default); the combined `.m4b` is a gapless, marker-less convenience path.
///
/// Keeping this exact signature means linking the real package later is a
/// one-file swap with no changes at the call site (`NarrationExportService`).
struct ChapterAtom {
    let startTime: Double
    let title: String
}

struct AudioMarker {
    /// Copies `sourceURL` to `outputURL`. `chapters` is accepted for API parity
    /// with `swift-audio-marker` but is **not written** — the combined audio is
    /// intact, only the chapter-navigation markers are absent until the package
    /// is linked (see the type doc).
    func writeChapters(_ chapters: [ChapterAtom], to sourceURL: URL, outputURL: URL) throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: outputURL)
    }
}
