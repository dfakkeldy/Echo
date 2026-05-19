import Foundation

/// Generic protocol for any media item that appears on a timeline —
/// audio chapters, video markers, bookmarks, flashcards, etc.
/// Designed so future video features share the same timeline rendering logic.
protocol MediaPlayable: Identifiable {
    /// Position in seconds within the media file.
    var mediaTimestamp: TimeInterval? { get }
    /// Display title.
    var title: String { get }
    /// Optional detail text.
    var subtitle: String? { get }
    /// The kind of content — drives icon and color in the feed.
    var timelineCardType: TimelineCardType { get }
}

/// Visual category for timeline feed cards.
enum TimelineCardType: String, CaseIterable {
    case chapter
    case bookmark
    case flashcard
    case note
    case transcription
    case track
    case voiceMemo
    case playbackSession
}
