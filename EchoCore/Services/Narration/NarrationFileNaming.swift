// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Single source of truth for narration cache filenames, so the writer
/// (`NarrationService`) and the exporter (`NarrationCacheSource`) always agree —
/// and so a `file://`-URL `audiobookID` (which contains slashes/colons) becomes a
/// valid filename instead of breaking the write.
nonisolated enum NarrationFileNaming {
    /// Bump whenever the *rendered audio* changes (DSP, sample rate, lead-out…),
    /// so a cached chapter from an older render misses the cache and regenerates
    /// once, while everything else stays persisted. v1 = the original un-versioned
    /// render (no `-v` suffix); v2 = 8.5 kHz low-pass (reverted — it dulled the
    /// already-clean render without fixing the whine, which was a playback-side
    /// time-pitch artifact); v3 = low-pass removed, raw vocoder output again;
    /// v4 = 0.75 s lead-out silence so the final word isn't clipped on chapter
    /// advance (NarrationService.leadOutPadSeconds);
    /// v5 = fixed-shape mattmireles Kokoro CoreML pipeline + MisakiSwift G2P
    /// (replaces FluidAudio's dynamic-shape vocoder) — different model, DSP, and
    /// G2P produce different bytes, so every cached chapter re-renders once.
    /// v6 = ONNX Runtime (CPU) Kokoro engine replaces the fixed-shape CoreML
    /// pipeline on iOS (instant load, RTF ≈ 0.5 on A14, off-ANE) — different
    /// acoustic model, so cached v5 audio regenerates once. (macOS still renders
    /// via CoreML until the ONNX port; the shared version means it re-renders too.)
    /// v7 = segment-render cache layout groundwork. The renderer still writes
    /// chapter files until segment orchestration lands, but the cache version
    /// changes so v6 per-chapter files are swept when the segment layout takes over.
    static let renderVersion = 7

    /// A filesystem-safe token for an audiobook id (which may be a folder-URL string).
    static func safeToken(_ audiobookID: String) -> String {
        let token = String(audiobookID.map { $0.isLetter || $0.isNumber ? $0 : "_" })
        return token.isEmpty ? "book" : token
    }

    static func chapterFileName(audiobookID: String, chapterIndex: Int, voice: VoiceID) -> String {
        "\(safeToken(audiobookID))-ch\(chapterIndex)-\(voice.rawValue)-v\(renderVersion).m4a"
    }

    static func segmentFileName(
        audiobookID: String, chapterIndex: Int, segmentIndex: Int, voice: VoiceID
    ) -> String {
        "\(safeToken(audiobookID))-ch\(chapterIndex)-s\(segmentIndex)-\(voice.rawValue)-v\(renderVersion).m4a"
    }

    /// Prefix matching every chapter file for a book (any chapter, any voice).
    static func chapterPrefix(audiobookID: String) -> String {
        "\(safeToken(audiobookID))-ch"
    }

    /// Recovers the chapter index from a name produced by `chapterFileName`,
    /// or `nil` if the name isn't a narration chapter file. Used to resume at the
    /// last-played chapter on reopen.
    static func chapterIndex(fromFileName fileName: String) -> Int? {
        guard let marker = fileName.range(of: "-ch") else { return nil }
        let digits = fileName[marker.upperBound...].prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    static func segmentLocation(fromFileName fileName: String) -> (
        chapterIndex: Int, segmentIndex: Int
    )? {
        guard let chapterMarker = fileName.range(of: "-ch") else { return nil }
        let chapterDigits = fileName[chapterMarker.upperBound...].prefix { $0.isNumber }
        guard let chapterIndex = Int(chapterDigits) else { return nil }
        guard
            let segmentMarker = fileName.range(
                of: "-s", range: chapterMarker.upperBound..<fileName.endIndex)
        else { return nil }
        let segmentDigits = fileName[segmentMarker.upperBound...].prefix { $0.isNumber }
        guard let segmentIndex = Int(segmentDigits) else { return nil }
        return (chapterIndex, segmentIndex)
    }
}

/// Pure helpers for keeping the rendered-narration directory tidy.
nonisolated enum NarrationCacheStore {
    /// File names belonging to `bookPrefix` that don't match the current voice
    /// *and* current render version — safe to delete when (re)rendering. This
    /// sweeps both stale-voice files and orphaned older-version renders (e.g. the
    /// un-versioned v1 files) so the cache doesn't grow without bound.
    static func staleVoiceFiles(
        _ fileNames: [String], bookPrefix: String, currentVoice: VoiceID
    ) -> [String] {
        let keepSuffix = "-\(currentVoice.rawValue)-v\(NarrationFileNaming.renderVersion).m4a"
        return fileNames.filter { $0.hasPrefix(bookPrefix) && !$0.hasSuffix(keepSuffix) }
    }
}
