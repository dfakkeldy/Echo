import Foundation
import Observation
import UIKit

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

    // MARK: - Playback

    var isPlaying: Bool = false
    var currentTitle: String = String(localized: "No track selected")
    var currentSubtitle: String = ""

    // MARK: - Progress

    var progressFraction: Double = 0.0
    var progressText: String = "--:--"
    var elapsedText: String = "--:--"
    var durationSeconds: Double? = nil

    // MARK: - Chapters

    var chapters: [Chapter] = []
    var currentChapterIndex: Int? = nil

    // MARK: - Flags

    var isManualSeeking: Bool = false
    var isSeekingForChapterBoundary: Bool = false
    var pauseTimestamp: Date? = nil

    // MARK: - Artwork

    var thumbnailImage: UIImage? = nil
    var currentDisplayArtwork: UIImage? = nil
    var currentDisplayArtworkVersion: Int = 0
    var watchThumbnailData: Data? = nil

    // MARK: - Transcript

    var transcription: [TranscriptionSegment] = []
    var enhancedTranscription: [EnhancedTranscriptionSegment] = []
    var chapterWordClouds: [Int: [WordFrequency]] = [:]
    var rollingWordClouds: [(startTime: TimeInterval, frequencies: [WordFrequency])] = []
    var isTranscriptProcessingEnabled: Bool = true
}
