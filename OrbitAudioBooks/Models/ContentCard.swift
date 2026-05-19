import Foundation

enum ContentCardType: String, Codable {
    case transcription
    case bookmark
    case flashcard
    case note
    case playbackSession
    case plannedSession
    case voiceMemo
    case chapterTransition
    case imageAsset
}

struct ContentCard: Identifiable, Equatable, PlaybackTimelineItem {
    let id: String
    let cardType: ContentCardType
    let title: String
    let subtitle: String?
    let mediaTimestamp: TimeInterval?
    let realTimestamp: Date
    let endedAt: Date?
    let sourceItemID: String?
    let sourceItemType: String?
    let isEditable: Bool
    let metadata: [String: String]

    init(
        id: String = UUID().uuidString,
        cardType: ContentCardType,
        title: String,
        subtitle: String? = nil,
        mediaTimestamp: TimeInterval? = nil,
        realTimestamp: Date = Date(),
        endedAt: Date? = nil,
        sourceItemID: String? = nil,
        sourceItemType: String? = nil,
        isEditable: Bool = false,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.cardType = cardType
        self.title = title
        self.subtitle = subtitle
        self.mediaTimestamp = mediaTimestamp
        self.realTimestamp = realTimestamp
        self.endedAt = endedAt
        self.sourceItemID = sourceItemID
        self.sourceItemType = sourceItemType
        self.isEditable = isEditable
        self.metadata = metadata
    }
}

extension ContentCard {
    init(from item: TimelineItem) {
        let cardType: ContentCardType = switch item.itemType {
        case .textSegment: .transcription
        case .chapterMarker: .chapterTransition
        case .imageAsset: .imageAsset
        case .bookmark: .bookmark
        case .ankiCard: .flashcard
        }
        self.init(
            id: item.id,
            cardType: cardType,
            title: item.title,
            subtitle: item.subtitle,
            mediaTimestamp: item.audioStartTime,
            realTimestamp: Date(),
            endedAt: nil,
            sourceItemID: item.id,
            sourceItemType: item.itemType.rawValue,
            isEditable: cardType == .bookmark || cardType == .note
        )
    }

    init(from event: RealTimeEvent) {
        let cardType: ContentCardType = switch event.eventType {
        case .playbackSession: .playbackSession
        case .bookmarkCreated: .bookmark
        case .flashcardReviewed: .flashcard
        case .voiceMemoRecorded: .voiceMemo
        case .noteCreated: .note
        case .plannedSessionCompleted: .plannedSession
        case .chapterTransition: .chapterTransition
        }

        self.init(
            id: event.id,
            cardType: cardType,
            title: event.title ?? "",
            subtitle: event.subtitle,
            mediaTimestamp: event.mediaTimestamp,
            realTimestamp: event.startedAt,
            endedAt: event.endedAt,
            sourceItemID: event.sourceItemID,
            sourceItemType: event.sourceItemType,
            isEditable: cardType == .note || cardType == .transcription || cardType == .bookmark
        )
    }
}

extension ContentCardType {
    /// Items that should appear at all zoom levels (chapters view + entries view).
    var isSummaryItem: Bool {
        switch self {
        case .bookmark, .flashcard, .note, .imageAsset: return true
        default: return false
        }
    }
}
