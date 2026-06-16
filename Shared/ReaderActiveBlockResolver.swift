// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Resolves the active (highlighted) EPUB block for read-along, scoped to the
/// **currently-playing track**.
///
/// ## Why this exists (Layer 1 of the multi-file read-along fix)
///
/// The audio engine reports a **per-track, 0-based** `currentTime`. The reader's
/// timeline cache, however, is one flat list of `[start, end)` ranges ordered by
/// `audio_start_time`. For a single-file book that is fine — there is one track
/// and one continuous axis. For a *multi-file* book (AI narration, an MP3 folder,
/// or several M4Bs) the per-track times collide: chapter 0 and chapter 1 both
/// have a block "at 5.0s". A plain binary search over the flat list always finds
/// the *first* row matching `5.0`, so the highlight gets stuck in chapter 0 no
/// matter which track is playing.
///
/// The fix is to scope resolution to the set of EPUB `chapter_index` values that
/// belong to the current track, then resolve by time *within that scope*. The
/// block→track mapping is derived at query time from `epub_block.chapter_index`
/// (no schema migration) and the player's current track.
///
/// This type is intentionally a tiny, pure, dependency-free helper living in
/// `Shared/` so that **both** the iOS reader (`ReaderFeedViewModel`) and the
/// macOS reader (`MacReaderFeedView`) call the exact same logic and cannot drift.
enum ReaderActiveBlockResolver {

    /// One timeline row: an audio `[start, end)` range mapped to an EPUB block,
    /// carrying the block's `chapterIndex` so resolution can be track-scoped.
    /// `chapterIndex == nil` denotes front-matter blocks (the importer leaves the
    /// chapter index null); those belong to track 0 only.
    typealias TimelineRow = (
        start: TimeInterval, end: TimeInterval, blockID: String, chapterIndex: Int?
    )

    /// Resolves the block whose audio range contains `time`, considering only the
    /// rows that belong to the current track.
    ///
    /// - Parameters:
    ///   - cache: Timeline rows. The function does **not** assume any ordering —
    ///     it filters by scope first, so it remains correct even when scoped rows
    ///     are interleaved with out-of-scope rows on the global axis.
    ///   - time: The current **per-track** playback time.
    ///   - currentTrackChapterIndices: The set of EPUB chapter indices in the
    ///     currently-playing track.
    ///       - `nil`  → **no scoping** (whole-book). Used for single-track books so
    ///         behavior is a strict no-op versus the legacy binary search.
    ///       - non-nil → consider only rows whose `chapterIndex` is in the set.
    ///         Rows with `chapterIndex == nil` (front matter) are treated as
    ///         belonging to **track 0 only**, i.e. included only when the set
    ///         contains `0`.
    /// - Returns: The matching block ID, or `nil` if no in-scope row covers `time`.
    static func activeBlockID(
        in cache: [TimelineRow],
        time: TimeInterval,
        currentTrackChapterIndices: Set<Int>?
    ) -> String? {
        if let scope = currentTrackChapterIndices {
            // Track-scoped: filter to the current track, then linear-scan by time.
            // The scoped slice is small (one chapter's worth of blocks for the
            // narration / MP3-folder 1:1 case), so a linear scan is cheap and
            // avoids any reliance on global ordering after filtering.
            let includesFrontMatter = scope.contains(0)
            for row in cache {
                let inScope: Bool
                if let chapter = row.chapterIndex {
                    inScope = scope.contains(chapter)
                } else {
                    // Front matter (nil chapter) belongs to track 0 only.
                    inScope = includesFrontMatter
                }
                guard inScope else { continue }
                if time >= row.start && time < row.end {
                    return row.blockID
                }
            }
            return nil
        }

        // Whole-book (legacy) path: binary search over the time-ordered cache.
        // Preserves the exact O(log N) behavior + [start, end) semantics that
        // single-track books relied on before track scoping existed.
        var low = 0
        var high = cache.count - 1
        while low <= high {
            let mid = low + (high - low) / 2
            let row = cache[mid]
            if time >= row.start && time < row.end {
                return row.blockID
            } else if time < row.start {
                high = mid - 1
            } else {
                low = mid + 1
            }
        }
        return nil
    }

    /// Computes the track-scoping set for read-along given an **already-resolved**
    /// playing chapter index.
    ///
    /// This is the bridge between "which track is the queue on" and the scoping set
    /// `activeBlockID(in:time:currentTrackChapterIndices:)` consumes. It lives here
    /// (not in the call sites) so iOS and macOS share one branch table and cannot
    /// drift, and it stays free of EchoCore deps so the macOS target — which does
    /// **not** import EchoCore and has no `NarrationFileNaming` — still compiles.
    ///
    /// The caller is responsible for resolving `playingChapterIndex` from whatever
    /// device-specific source it has (e.g. iOS parses the narration track filename).
    /// Here we only encode the policy (evaluated in this order):
    ///
    /// - `playingChapterIndex` provided (narration): scope to **that chapter**, even
    ///   when it differs from `currentIndex` (resume front-truncates the plan, or a
    ///   dropped image-only chapter leaves a gap → queue position ≠ chapter index)
    ///   and even when only a SINGLE track is queued (forward-only resume injects
    ///   `tracks == [oneTrack]`, so `trackCount == 1` but the track is still
    ///   chapter N — a whole-book fallback would mis-highlight).
    /// - Single track (`trackCount <= 1`) with no known chapter: `nil` → no scoping.
    ///   One continuous axis, so the legacy whole-book search is correct (no-op).
    /// - Multi-M4B (always `playingChapterIndex == nil`): `nil` → no scoping. One
    ///   .m4b aggregates many chapters whose per-book index does not reliably map
    ///   onto the EPUB global `chapter_index`; scoping would risk mis-highlighting,
    ///   so fall back to the whole-book axis.
    /// - `playingChapterIndex == nil` (MP3 folder), multi-track: track position
    ///   equals the EPUB chapter index 1:1, so fall back to `{currentIndex}`.
    ///
    /// - Parameters:
    ///   - trackCount: Number of tracks in the playback queue.
    ///   - isMultiM4B: Whether the book is a multi-M4B aggregate.
    ///   - currentIndex: The current track **position** in the queue.
    ///   - playingChapterIndex: The EPUB chapter index of the currently-playing
    ///     track, when it is known (narration); `nil` otherwise (MP3 folder).
    /// - Returns: The scoping set for `activeBlockID`, or `nil` for no scoping.
    static func trackChapterScope(
        trackCount: Int,
        isMultiM4B: Bool,
        currentIndex: Int,
        playingChapterIndex: Int?
    ) -> Set<Int>? {
        // A known playing chapter (narration parsed the `ch{N}` filename) scopes
        // to that chapter BEFORE the `trackCount > 1` guard: forward-only resume
        // injects a SINGLE track (`tracks == [oneTrack]`, trackCount == 1) that is
        // still chapter N, not the whole book. Returning nil here would fall back
        // to a whole-book search and mis-highlight. Multi-M4B never reaches this
        // (it always passes `playingChapterIndex == nil`).
        if let chapter = playingChapterIndex { return [chapter] }
        // No known playing chapter. Single track / multi-M4B → no scoping
        // (whole-book legacy axis); MP3 folder (trackCount > 1) → {currentIndex},
        // since track position equals the EPUB chapter index 1:1.
        guard trackCount > 1, !isMultiM4B else { return nil }
        return [currentIndex]
    }
}
