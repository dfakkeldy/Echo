// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

/// Whether a book's reader text is genuinely aligned to its audio, and how far
/// that alignment reaches.
///
/// "Does this book have a timeline?" and "is this book aligned?" are different
/// questions in Echo, and conflating them misleads the reader. At import
/// `TimelineIngestionFactory` spreads every block across its chapter by word
/// count and stamps it `AlignmentStatus.estimated`, so a book that has never
/// been near an aligner still scrolls, still highlights, and still looks
/// aligned. Only `lockedAnchor` (a real anchor sits on this block) and
/// `interpolated` (this block lies between two real anchors) describe a
/// position derived from the audio itself.
///
/// This type is deliberately free of any UI vocabulary: it reports the state
/// and the counts behind it, and each platform's view decides how to word them.
///
/// `nonisolated` because the app targets build with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`: without it every member here —
/// including the pure `make(...)` classifier — would be main-actor-isolated,
/// and ``load(audiobookID:db:)`` could not call them from the background.
/// Conforming to `Sendable` alone does not opt a type out.
nonisolated struct BookAlignmentSummary: Equatable, Sendable {
    /// How the book's text relates to its audio, worst to best.
    enum State: String, Sendable {
        /// No reader text at all — there is nothing to align.
        case noText
        /// Text exists but no block has any audio position.
        case unaligned
        /// Every position is the importer's word-count guess. The reader will
        /// scroll, but it is not following the audio.
        case estimated
        /// Real anchors exist, but under ``BookAlignmentSummary/alignedThreshold``
        /// of the text resolves through them.
        case partial
        /// Real anchors cover the book.
        case aligned
    }

    /// Coverage at or above which the book counts as `.aligned`.
    ///
    /// Deliberately below 1.0: front matter, back matter, and any block outside
    /// the first and last anchor keep their imported estimate even after a
    /// clean DTW run, so demanding full coverage would label almost every real
    /// book "partly aligned" and make the badge noise. The exact percentage is
    /// always reported alongside the state, so the softer bar never hides a
    /// weak alignment.
    static let alignedThreshold = 0.75

    let state: State
    /// Anchors that represent real alignment work — everything except the
    /// structural `chapterBoundary` seeds written at import.
    let realAnchorCount: Int
    /// Every anchor row for the book, seeds included.
    let totalAnchorCount: Int
    /// Text blocks whose audio position derives from a real anchor
    /// (`lockedAnchor` or `interpolated`).
    let anchoredBlockCount: Int
    /// Visible text blocks in the book. The denominator for ``coverage``.
    let textBlockCount: Int

    /// Fraction of the book's visible text that resolves through real anchors,
    /// 0...1. Zero when there is no text, so callers never divide by zero.
    var coverage: Double {
        guard textBlockCount > 0 else { return 0 }
        return min(1.0, Double(anchoredBlockCount) / Double(textBlockCount))
    }

    /// ``coverage`` as a whole percentage, for display.
    var coveragePercent: Int { Int((coverage * 100).rounded()) }

    /// Whether the book is aligned well enough for read-along to follow audio.
    var isAligned: Bool { state == .aligned }

    // MARK: - Derivation

    /// Classifies a book from its raw counts. Pure, so the state machine is
    /// testable without a database.
    ///
    /// - Parameters:
    ///   - textBlockCount: Visible `epub_block` rows.
    ///   - timedBlockCount: Blocks carrying any audio position, estimates
    ///     included. Distinguishes "never given a timeline" from "given a
    ///     guessed one".
    ///   - anchoredBlockCount: Blocks positioned by a real anchor.
    ///   - realAnchorCount: Non-seed anchors.
    ///   - totalAnchorCount: All anchors.
    static func make(
        textBlockCount: Int,
        timedBlockCount: Int,
        anchoredBlockCount: Int,
        realAnchorCount: Int,
        totalAnchorCount: Int
    ) -> BookAlignmentSummary {
        // Clamp the numerators: a book can hold more timeline rows than visible
        // blocks (hidden blocks keep their rows), and a coverage above 100%
        // would be nonsense in the badge.
        let anchored = max(0, min(anchoredBlockCount, textBlockCount))
        let summary = BookAlignmentSummary(
            state: .unaligned,
            realAnchorCount: max(0, realAnchorCount),
            totalAnchorCount: max(0, totalAnchorCount),
            anchoredBlockCount: anchored,
            textBlockCount: max(0, textBlockCount)
        )

        let state: State
        if textBlockCount <= 0 {
            state = .noText
        } else if realAnchorCount <= 0 || anchored <= 0 {
            // No real anchors, or none of them landed on visible text. Whether
            // the reader still scrolls depends on the imported estimate.
            state = timedBlockCount > 0 ? .estimated : .unaligned
        } else if summary.coverage >= alignedThreshold {
            state = .aligned
        } else {
            state = .partial
        }

        return BookAlignmentSummary(
            state: state,
            realAnchorCount: summary.realAnchorCount,
            totalAnchorCount: summary.totalAnchorCount,
            anchoredBlockCount: summary.anchoredBlockCount,
            textBlockCount: summary.textBlockCount
        )
    }

    /// The summary for a book with no reader text.
    static let empty = BookAlignmentSummary(
        state: .noText,
        realAnchorCount: 0,
        totalAnchorCount: 0,
        anchoredBlockCount: 0,
        textBlockCount: 0
    )

    // MARK: - Loading

    /// Reads the four counts this summary needs.
    ///
    /// Synchronous on purpose. A plain `nonisolated async` function still runs
    /// on the caller's actor under `SWIFT_APPROACHABLE_CONCURRENCY`, so an
    /// `async` spelling here would quietly do its database work on the UI
    /// actor while *looking* like it had moved off it. Callers that care hop
    /// off main themselves (`Task.detached`); the queries are three indexed
    /// `COUNT`s, so a direct call is also fine.
    static func load(audiobookID: String, db: any DatabaseReader) throws
        -> BookAlignmentSummary
    {
        try db.read { database in
            let textBlockCount =
                try Int.fetchOne(
                    database,
                    sql: """
                        SELECT COUNT(*) FROM epub_block
                        WHERE audiobook_id = ? AND is_hidden = 0
                        """,
                    arguments: [audiobookID]) ?? 0

            let anchorRow = try Row.fetchOne(
                database,
                sql: """
                    SELECT COUNT(*) AS total,
                           SUM(CASE WHEN source <> ? THEN 1 ELSE 0 END) AS real
                    FROM alignment_anchor
                    WHERE audiobook_id = ?
                    """,
                arguments: [AlignmentAnchorRecord.Source.chapterBoundary.rawValue, audiobookID])

            let blockRow = try Row.fetchOne(
                database,
                sql: """
                    SELECT SUM(CASE WHEN alignment_status IN (?, ?) THEN 1 ELSE 0 END) AS anchored,
                           SUM(CASE WHEN audio_start_time >= 0 THEN 1 ELSE 0 END) AS timed
                    FROM timeline_item
                    WHERE audiobook_id = ? AND epub_block_id IS NOT NULL
                    """,
                arguments: [
                    AlignmentStatus.lockedAnchor.rawValue,
                    AlignmentStatus.interpolated.rawValue,
                    audiobookID,
                ])

            // `SUM` over zero rows is SQL NULL, so every aggregate is optional.
            return make(
                textBlockCount: textBlockCount,
                timedBlockCount: blockRow?["timed"] ?? 0,
                anchoredBlockCount: blockRow?["anchored"] ?? 0,
                realAnchorCount: anchorRow?["real"] ?? 0,
                totalAnchorCount: anchorRow?["total"] ?? 0
            )
        }
    }
}
