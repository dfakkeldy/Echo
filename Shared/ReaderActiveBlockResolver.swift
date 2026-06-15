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
}
