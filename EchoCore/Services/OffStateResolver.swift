// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

/// The single reconciled on/off state of one feed chapter, derived from the two
/// independent persistence systems: audio (`.echoplaylist.json` track `enabled`
/// flags) and EPUB text (`epub_block.is_hidden`).
enum ChapterOffState: Equatable, Sendable {
    /// Both audio and EPUB are on.
    case allOn
    /// Audio is off (all backing tracks disabled) but EPUB text is visible.
    case audioOff
    /// EPUB text is hidden but audio is on.
    case epubOff
    /// Both off.
    case allOff

    var isAudioOff: Bool { self == .audioOff || self == .allOff }
    var isEpubOff: Bool { self == .epubOff || self == .allOff }
    /// Whether the whole chapter should render greyed-out (anything is off).
    var isDimmed: Bool { self != .allOn }
}

/// Reconciles the two off-switch systems into one read truth, and performs the
/// correct write per heading kind. Pure (no UIKit); reusable on macOS.
///
/// - Audio off lives in `.echoplaylist.json` (`PlaylistManifestService`), keyed
///   per *track file*. A chapter is audio-off iff **all** of its backing track
///   files have `enabled == false`.
/// - EPUB off lives in `epub_block.is_hidden` (GRDB), keyed per `chapter_index`.
struct OffStateResolver {
    let db: DatabaseWriter
    /// The playlist folder holding `.echoplaylist.json`. `nil` for books with no
    /// audio sidecar (e.g. text-only / not-yet-synced) — audio then reads as on.
    let folderURL: URL?

    // MARK: Read

    func resolve(audiobookID: String, chapterIndex: Int, trackFiles: [String]) throws
        -> ChapterOffState
    {
        let epubOff = try isEpubChapterHidden(audiobookID: audiobookID, chapterIndex: chapterIndex)
        let audioOff = isAudioOff(trackFiles: trackFiles)
        switch (audioOff, epubOff) {
        case (false, false): return .allOn
        case (true, false): return .audioOff
        case (false, true): return .epubOff
        case (true, true): return .allOff
        }
    }

    /// A chapter's EPUB text is hidden iff it has at least one block and *every*
    /// block is `is_hidden`. (A chapter with zero blocks reads as not-hidden.)
    private func isEpubChapterHidden(audiobookID: String, chapterIndex: Int) throws -> Bool {
        try db.read { db in
            let total =
                try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM epub_block
                        WHERE audiobook_id = ? AND chapter_index = ?
                        """,
                    arguments: [audiobookID, chapterIndex]) ?? 0
            guard total > 0 else { return false }
            let visible =
                try Int.fetchOne(
                    db,
                    sql: """
                        SELECT COUNT(*) FROM epub_block
                        WHERE audiobook_id = ? AND chapter_index = ? AND is_hidden = 0
                        """,
                    arguments: [audiobookID, chapterIndex]) ?? 0
            return visible == 0
        }
    }

    /// Audio is off iff there is a manifest, the chapter has backing tracks, and
    /// every backing track is disabled.
    private func isAudioOff(trackFiles: [String]) -> Bool {
        guard let folderURL, !trackFiles.isEmpty,
            let manifest = PlaylistManifestService.read(from: folderURL)
        else { return false }
        let backing =
            trackFiles
            .compactMap { file in manifest.tracks.first(where: { $0.file == file }) }
        guard !backing.isEmpty else { return false }
        return backing.allSatisfy { !$0.enabled }
    }

    // MARK: Write

    func setEpubOff(_ off: Bool, audiobookID: String, chapterIndex: Int) throws {
        let dao = EPubBlockDAO(db: db)
        if off {
            try dao.hideChapter(
                chapterIndex: chapterIndex, audiobookID: audiobookID, reason: "userOff")
        } else {
            try dao.unhideChapter(chapterIndex: chapterIndex, audiobookID: audiobookID)
        }
    }

    func setAudioOff(_ off: Bool, trackFiles: [String]) throws {
        guard let folderURL, !trackFiles.isEmpty else { return }
        var states: [String: Bool] = [:]
        for file in trackFiles { states[file] = !off }  // enabled = !off
        PlaylistManifestService.updateEnabledStates(folderURL: folderURL, states: states)
    }

    /// Best-effort "turn off everywhere": write GRDB first (the feed-truth side),
    /// then the manifest. If the manifest write is impossible (no folder) the EPUB
    /// write still stands and the feed renders correctly.
    func setAllOff(
        _ off: Bool, audiobookID: String, chapterIndex: Int, trackFiles: [String]
    ) throws {
        try setEpubOff(off, audiobookID: audiobookID, chapterIndex: chapterIndex)
        try setAudioOff(off, trackFiles: trackFiles)
    }
}
