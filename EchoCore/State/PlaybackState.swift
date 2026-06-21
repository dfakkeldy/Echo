// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Observation

#if os(iOS)
    import UIKit
#endif

/// Shared mutable playback state, owned by PlaybackController and observed by
/// both PlayerModel (via pass-through computed properties) and SwiftUI views.
/// Eliminates ~150 lines of stored properties and pass-throughs from PlayerModel.
@MainActor @Observable
final class PlaybackState {
    // MARK: - Playlist

    var folderURL: URL? = nil
    var tracks: [Track] = []
    var currentIndex: Int = 0

    // MARK: - Multi-M4B Aggregation

    var m4bBooks: [M4BBook] = []
    var aggregatedChapters: [AggregatedChapter] = []
    var totalBookDuration: TimeInterval = 0

    var isMultiM4B: Bool { m4bBooks.count >= 2 }
    var pendingAggregatedChapter: AggregatedChapter? = nil

    /// The M4B file currently playing, resolved by matching the playing track's
    /// URL against `m4bBooks`. `currentIndex` indexes `tracks`, which is
    /// independently reorderable via persisted `loadOrder`/`moveTracks`, so it must
    /// NOT be used to index the filename-sorted `m4bBooks` — doing so returns the
    /// wrong book's offset after a manual reorder (CODE_AUDIT §5.1).
    var currentBook: M4BBook? {
        guard tracks.indices.contains(currentIndex) else { return nil }
        let playingURL = tracks[currentIndex].url
        return m4bBooks.first { $0.url == playingURL }
    }

    /// Cumulative start offset (book-global time base) of the currently playing
    /// book, or 0 when single-file / unresolved.
    var currentBookStartOffset: TimeInterval { currentBook?.cumulativeStartOffset ?? 0 }

    /// Whole-book duration for the current playback scope: the aggregated total
    /// for a multi-M4B folder, otherwise the single file's duration. Centralizes
    /// the `isMultiM4B ? totalBookDuration : durationSeconds` selection that
    /// book-level progress, scrubbing, and remote (Audiobookshelf) sync must use —
    /// dividing a book-absolute time by the current *track's* duration reads as
    /// finished after the first track (CODE_AUDIT §5.20).
    var effectiveBookDuration: TimeInterval {
        isMultiM4B ? totalBookDuration : (durationSeconds ?? 0)
    }

    // MARK: - Playback

    var isPlaying: Bool = false
    var currentTitle: String = String(localized: "No track selected")
    var currentSubtitle: String = ""

    // MARK: - Progress

    var progressFraction: Double = 0.0
    /// Coarse 0–100 book-level progress, updated only when the integer changes
    /// so dashboard cards observing it re-render ~1 Hz, not per playback tick (§7.3).
    var bookProgressPercent: Int = 0
    var progressText: String = "--:--"
    var elapsedText: String = "--:--"
    /// Total duration of the current scope (chapter or book), un-negated.
    /// Shown when the trailing scrubber label is toggled off "remaining".
    var durationText: String = "--:--"
    var durationSeconds: Double? = nil

    // MARK: - Chapters

    var chapters: [Chapter] = []
    var currentChapterIndex: Int? = nil
    /// Full EPUB chapter outline for a narration book (every narratable chapter,
    /// independent of render progress), shown on the playlist page with
    /// tap-to-exclude. Empty for non-narration books. See NarrationOutlineBuilder.
    var narrationOutline: [NarrationOutlineChapter] = []
    /// Fine-grained sub-section atoms per logical chapter index.
    /// Populated by `ChapterGroupingService` when a Libation-style naming
    /// pattern is detected; empty for all other books.
    var chapterSections: [Int: [Chapter]] = [:]

    // MARK: - Flags

    var isManualSeeking: Bool = false
    var isSeekingForChapterBoundary: Bool = false
    var pauseTimestamp: Date? = nil

    // MARK: - Artwork

    #if os(iOS)
        var thumbnailImage: UIImage? = nil
        var currentDisplayArtwork: UIImage? = nil
    #endif
    var currentDisplayArtworkVersion: Int = 0
    var watchThumbnailData: Data? = nil

    // MARK: - Transcript

    var transcription: [TranscriptionSegment] = []
    var enhancedTranscription: [EnhancedTranscriptionSegment] = []
    var chapterWordClouds: [Int: [WordFrequency]] = [:]
    var rollingWordClouds: [(startTime: TimeInterval, frequencies: [WordFrequency])] = []
    var isTranscriptProcessingEnabled: Bool = true

    /// A trigger used to force UI re-evaluations when documents (EPUB/PDF) are imported or replaced.
    var documentIngestionTrigger: Int = 0

    // MARK: - On-device narration playback

    /// `true` while narration chapters are still being rendered and appended as
    /// tracks. Lets `nextTrack()` wait at the end of the rendered queue instead
    /// of looping back to chapter 1 when the next chapter isn't ready yet.
    var narrationRenderInFlight: Bool = false
    /// Set when playback reached the end of the rendered narration queue and is
    /// paused waiting for the next chapter; `startNarrationPlayback` resumes once
    /// that chapter is appended.
    var awaitingNarrationChapter: Bool = false
}
