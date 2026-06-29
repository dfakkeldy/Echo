// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Observation

#if os(iOS)
    import UIKit
#endif

/// Shared book-absolute timing for playlist playback, manifest resume, Watch
/// context, and Audiobookshelf progress sync.
struct PlaybackBookTimeIndex: Equatable, Sendable {
    struct TrackTime: Equatable, Sendable {
        var trackID: String
        var trackURL: URL
        var trackIndex: Int
        var startTime: TimeInterval
        var duration: TimeInterval

        var endTime: TimeInterval { startTime + duration }
    }

    struct ResolvedTime: Equatable, Sendable {
        var trackID: String
        var trackURL: URL
        var trackIndex: Int
        var offset: TimeInterval
        var duration: TimeInterval
    }

    static let empty = PlaybackBookTimeIndex(tracks: [])

    var tracks: [TrackTime]

    var totalDuration: TimeInterval {
        tracks.last.map(\.endTime) ?? 0
    }

    init(tracks: [TrackTime]) {
        self.tracks = tracks
            .filter { $0.duration.isFinite && $0.duration > 0 }
            .sorted {
                if $0.startTime == $1.startTime { return $0.trackIndex < $1.trackIndex }
                return $0.startTime < $1.startTime
            }
    }

    init(orderedTracks: [(track: Track, duration: TimeInterval)]) {
        var cursor: TimeInterval = 0
        var values: [TrackTime] = []
        for (index, item) in orderedTracks.enumerated() {
            guard item.duration.isFinite, item.duration > 0 else { continue }
            values.append(
                TrackTime(
                    trackID: item.track.id,
                    trackURL: item.track.url,
                    trackIndex: index,
                    startTime: cursor,
                    duration: item.duration))
            cursor += item.duration
        }
        self.init(tracks: values)
    }

    func startTime(forTrackID trackID: String) -> TimeInterval? {
        tracks.first { $0.trackID == trackID }?.startTime
    }

    func startTime(forTrackURL trackURL: URL) -> TimeInterval? {
        tracks.first { $0.trackURL == trackURL }?.startTime
    }

    func bookTime(trackID: String, offset: TimeInterval) -> TimeInterval? {
        guard let track = tracks.first(where: { $0.trackID == trackID }) else { return nil }
        return track.startTime + min(max(0, offset), track.duration)
    }

    func resolve(bookTime: TimeInterval) -> ResolvedTime? {
        guard let first = tracks.first else { return nil }
        let clamped = min(max(0, bookTime), totalDuration)
        let track =
            tracks.first { clamped >= $0.startTime && clamped < $0.endTime }
            ?? tracks.last
            ?? first
        return ResolvedTime(
            trackID: track.trackID,
            trackURL: track.trackURL,
            trackIndex: track.trackIndex,
            offset: min(max(0, clamped - track.startTime), track.duration),
            duration: track.duration)
    }
}

/// Shared mutable playback state, owned by PlaybackController and observed by
/// both PlayerModel (via pass-through computed properties) and SwiftUI views.
/// Eliminates ~150 lines of stored properties and pass-throughs from PlayerModel.
@MainActor @Observable
final class PlaybackState {
    // MARK: - Playlist

    var folderURL: URL? = nil
    var sourceDocumentURL: URL? = nil
    var tracks: [Track] = []
    var currentIndex: Int = 0

    // MARK: - Multi-M4B Aggregation

    var m4bBooks: [M4BBook] = []
    var aggregatedChapters: [AggregatedChapter] = []
    var totalBookDuration: TimeInterval = 0
    var bookTimeIndex: PlaybackBookTimeIndex = .empty
    var pendingBookTimeSeek: TimeInterval? = nil
    var pendingBookTimeSeekSuppressesProgressPush: Bool = false

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

    var currentTrackStartOffset: TimeInterval {
        guard tracks.indices.contains(currentIndex) else { return 0 }
        let track = tracks[currentIndex]
        return bookTimeIndex.startTime(forTrackID: track.id)
            ?? bookTimeIndex.startTime(forTrackURL: track.url)
            ?? currentBookStartOffset
    }

    /// Whole-book duration for the current playback scope: the aggregated total
    /// for a multi-M4B folder, otherwise the single file's duration. Centralizes
    /// the `isMultiM4B ? totalBookDuration : durationSeconds` selection that
    /// book-level progress, scrubbing, and remote (Audiobookshelf) sync must use —
    /// dividing a book-absolute time by the current *track's* duration reads as
    /// finished after the first track (CODE_AUDIT §5.20).
    var effectiveBookDuration: TimeInterval {
        if bookTimeIndex.totalDuration > 0 { return bookTimeIndex.totalDuration }
        return isMultiM4B ? totalBookDuration : (durationSeconds ?? 0)
    }

    func bookTime(forCurrentTrackOffset offset: TimeInterval) -> TimeInterval {
        guard tracks.indices.contains(currentIndex), offset.isFinite else { return 0 }
        let track = tracks[currentIndex]
        return bookTimeIndex.bookTime(trackID: track.id, offset: offset)
            ?? (currentBookStartOffset + max(0, offset))
    }

    func trackOffset(forBookTime bookTime: TimeInterval, trackID: String) -> TimeInterval? {
        guard let resolved = bookTimeIndex.resolve(bookTime: bookTime),
            resolved.trackID == trackID
        else { return nil }
        return resolved.offset
    }

    func shouldDeferBookTimeSeek(_ target: TimeInterval) -> Bool {
        tracks.count > 1 && target.isFinite && bookTimeIndex.resolve(bookTime: target) == nil
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
