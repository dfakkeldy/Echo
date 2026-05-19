import Foundation

// MARK: - Audiobook Card Info

/// Lightweight view-model struct for displaying an audiobook as a card
/// in the Timeline feed at `.book` / Library scope.
struct AudiobookCardInfo: Identifiable, Equatable {
    let id: String
    let title: String
    let author: String?
    let duration: TimeInterval
    let fileCount: Int?
    let isCurrentlyPlaying: Bool
    let addedAt: String
}

// MARK: - Timeline Display Item

/// Unified enum wrapping all item types that can appear in the Timeline feed.
/// Replaces the previous ad-hoc system of `[TimelineItem]` + string-identified
/// gap/nowline sentinels with a single typed array.
enum TimelineDisplayItem: Identifiable, Equatable {
    /// A book from the user's library (`.book` scope).
    case audiobookCard(AudiobookCardInfo)

    /// Any database-persisted timeline item (chapter marker, text segment,
    /// bookmark, flashcard, image asset).
    case timelineItem(TimelineItem)

    /// The "NOW" playhead divider line.
    case nowLine

    /// An elastic scrubber gap between two distant items.
    case scrubberGap(duration: TimeInterval, id: String)

    // MARK: - Identifiable

    var id: String {
        switch self {
        case .audiobookCard(let info):
            return "audiobook-\(info.id)"
        case .timelineItem(let item):
            return item.id
        case .nowLine:
            return "__now_line__"
        case .scrubberGap(_, let id):
            return id
        }
    }

    // MARK: - Equatable

    static func == (lhs: TimelineDisplayItem, rhs: TimelineDisplayItem) -> Bool {
        lhs.id == rhs.id
    }

    // MARK: - Convenience accessors

    var audiobookCard: AudiobookCardInfo? {
        if case .audiobookCard(let info) = self { return info }
        return nil
    }

    var timelineItem: TimelineItem? {
        if case .timelineItem(let item) = self { return item }
        return nil
    }

    var scrubberGapDuration: TimeInterval? {
        if case .scrubberGap(let duration, _) = self { return duration }
        return nil
    }
}
