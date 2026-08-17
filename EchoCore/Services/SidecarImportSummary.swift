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
        /// A sidecar resolved and was ingested. Its word timings were applied to
        /// ≥1 block, OR it carried no word timings at all (an anchors-only
        /// sidecar — the shape every Mac-batch DTW export has). The second case
        /// used to be misfiled as `.foundButUnresolved`: applying word timings is
        /// a no-op by definition when no anchor carries any, so a fully
        /// successful block-level ingest reported itself as a failure.
        case applied
        /// A sidecar was found but did not take effect: either zero portable
        /// `s<i>-b<j>` ids resolved to local blocks (block-id schemes diverged),
        /// or it carried word timings and not one block accepted them. Read-along
        /// falls back to interpolation, so the book still highlights, just
        /// estimated.
        case foundButUnresolved
        /// The sidecar sits in iCloud undownloaded and could not be pulled in
        /// time; a later open retries the download.
        case notDownloaded
        /// The sidecar file was present but could not be decoded.
        case decodeError
        /// The sidecar targets a different parsed source revision, or lacks
        /// identity on a source where code blocks can shift legacy suffixes.
        case staleSource
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
        case .applied:
            // Ingested successfully; the file simply has no per-word timings to
            // give (anchors-only sidecars are the norm, not a fault).
            return "Paragraph-level — alignment file applied, no word timings"
        case .foundButUnresolved:
            return "Paragraph-level — alignment file found but not applied"
        case .notDownloaded:
            return "Paragraph-level — alignment file not downloaded from iCloud"
        case .decodeError:
            return "Paragraph-level — alignment file unreadable"
        case .staleSource:
            // Name the side that is actually out of date. The alignment file is
            // current — it is the imported book text that no longer matches it
            // (an EPUB edited or re-issued after the alignment was produced), and
            // `AlignmentSidecar.sourceValidation` fails closed on the first
            // mismatching anchor. Blaming the file sent users hunting for a
            // "stale" sidecar they could not fix.
            return "Paragraph-level — imported book text no longer matches the alignment file"
        case .noSidecar:
            return "Paragraph-level (no word timings)"
        }
    }

    /// The one action that repairs the current state, or `nil` when there is
    /// nothing for the user to do. Only `.staleSource` is user-fixable: automatic
    /// recovery re-imports the source by itself when the file on disk would
    /// validate, so a `.staleSource` that is still being reported has already
    /// failed that check and needs the *document* replaced, not retried.
    var readAlongRecoveryHint: String? {
        guard blocksMatched == 0, status == .staleSource else { return nil }
        return "Re-import the book with More → Replace Document… to restore read-along."
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

    /// The repair action for the current state, or `nil` when there is nothing
    /// actionable. Books with no persisted summary never produce a hint: without
    /// a snapshot we cannot tell a healthy paragraph-level book from a broken one
    /// and must not send the user to a destructive re-import on a guess.
    static func recoveryHint(
        audiobookID: String,
        store: UserDefaults = .standard
    ) -> String? {
        BookPreferencesService.loadSidecarSummary(for: audiobookID, store: store)?
            .readAlongRecoveryHint
    }
}
