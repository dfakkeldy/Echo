// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

/// A frozen snapshot of what the alignment-sidecar import did for one book, so
/// Book Settings can honestly report whether word-level read-along is active —
/// and, when it isn't, *why*. That "why" is the observability gap the J-Space
/// device QA flagged: a book can silently degrade to block-level read-along and
/// nothing in the UI explains it.
///
/// Persisted per book via `BookPreferencesService` rather than derived live
/// from `word_timing`, for two reasons the QA investigation surfaced:
/// - The degraded-case reason (a sidecar was found but zero portable
///   `s<i>-b<j>` ids resolved, or the file is an undownloaded iCloud
///   placeholder) is a discovery-time fact no `word_timing` row records.
/// - A live `source == "sidecar"` count silently reads zero once a later
///   in-app auto-alignment rebuilds those rows — so a snapshot taken at import
///   time is the only stable record of what the sidecar contributed.
/// `nonisolated` so the off-main import task (`DocumentImportFinalizer`) can
/// JSON-encode it: under the iOS target's main-actor default isolation a plain
/// value type's synthesized `Codable` conformance would otherwise be
/// main-actor-isolated and unusable from a `nonisolated` context.
nonisolated struct SidecarImportSummary: Codable, Equatable, Sendable {
    /// The terminal outcome of the sidecar pass for this finalize.
    enum Status: String, Codable, Sendable {
        /// A sidecar resolved and its word timings were applied to ≥1 block.
        case applied
        /// A sidecar was found but zero portable `s<i>-b<j>` ids resolved to
        /// local blocks (block-id schemes diverged) — read-along falls back to
        /// interpolation, so the book still highlights, just estimated.
        case foundButUnresolved
        /// The sidecar sits in iCloud undownloaded and could not be pulled in
        /// time; a later open retries the download.
        case notDownloaded
        /// The sidecar file was present but could not be decoded.
        case decodeError
        /// No sidecar (or iCloud placeholder) was found next to the book.
        case noSidecar
    }

    var status: Status
    /// Whether an `alignment.json` (or its iCloud placeholder) was detected.
    var sidecarFound: Bool
    /// Blocks that took true sidecar word timings.
    var blocksMatched: Int
    /// Sidecar word rows written across `blocksMatched`.
    var wordsWritten: Int
    /// Text blocks the book was imported with (the "/755" denominator).
    var totalBlocks: Int
    /// ISO-8601 timestamp of the finalize that wrote this snapshot.
    var updatedAt: String

    /// A one-line, honest description of read-along state for Book Settings.
    /// Front-loads "Word-level" vs "Paragraph-level" so the headline survives
    /// truncation; the degraded cases name the reason.
    var readAlongStatusLine: String {
        if blocksMatched > 0 {
            return "Word-level (sidecar, \(blocksMatched)/\(totalBlocks) blocks)"
        }
        switch status {
        case .applied, .foundButUnresolved:
            return "Paragraph-level — alignment file found but not applied"
        case .notDownloaded:
            return "Paragraph-level — alignment file not downloaded from iCloud"
        case .decodeError:
            return "Paragraph-level — alignment file unreadable"
        case .noSidecar:
            return "Paragraph-level (no word timings)"
        }
    }
}

/// Resolves the Book Settings read-along status line for a book, preferring the
/// persisted `SidecarImportSummary` snapshot (authoritative for *why* read-along
/// is or isn't word-level) and falling back to a live `word_timing` check for
/// books imported before summaries were recorded.
enum ReadAlongStatusResolver {
    static func statusLine(
        audiobookID: String,
        writer: DatabaseWriter,
        store: UserDefaults = .standard
    ) -> String {
        if let summary = BookPreferencesService.loadSidecarSummary(for: audiobookID, store: store) {
            return summary.readAlongStatusLine
        }
        // No snapshot (pre-feature import): the reader keys purely on row
        // presence, so mirror that — we just can't name the source.
        let hasWords =
            (try? WordTimingDAO(db: writer).hasWordTimings(forAudiobook: audiobookID)) ?? false
        return hasWords
            ? "Word-level (aligned)"
            : "Paragraph-level (no word timings)"
    }
}
