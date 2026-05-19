import Foundation

/// Generic protocol for any media item that appears on a timeline —
/// audio chapters, video markers, bookmarks, flashcards, etc.
/// Designed so future video features share the same timeline rendering logic.
protocol MediaPlayable: Identifiable {
    /// When this segment begins in the media timeline (seconds).
    var audioStartTime: TimeInterval { get }
    /// When this segment ends, if it has a duration.
    /// Point-in-time items (bookmarks, images) return nil.
    var audioEndTime: TimeInterval? { get }
    /// Display title for the feed cell.
    var title: String { get }
    /// Optional detail text.
    var subtitle: String? { get }
    /// The kind of content — drives icon and color in the feed.
    var timelineCardType: TimelineCardType { get }
}

/// Visual category for timeline feed cards.
enum TimelineCardType: String, CaseIterable {
    case textSegment
    case chapterMarker
    case imageAsset
    case bookmark
    case ankiCard
}
