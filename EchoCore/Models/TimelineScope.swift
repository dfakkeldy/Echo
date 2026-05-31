import Foundation

/// Structural zoom level for the unified Timeline feed.
/// Represents depth of detail: from the library shelf down to individual words.
enum TimelineScope: String, CaseIterable, Identifiable, Sendable {
    case book
    case chapter
    case transcription

    var id: String { rawValue }

    var label: String {
        switch self {
        case .book:          String(localized: "Library")
        case .chapter:       String(localized: "Ch")
        case .transcription: String(localized: "Trans")
        }
    }

    var menuLabel: String {
        switch self {
        case .book:          String(localized: "Library")
        case .chapter:       String(localized: "Chapter")
        case .transcription: String(localized: "Transcription")
        }
    }

    var calendarComponent: Calendar.Component {
        switch self {
        case .book:          .day
        case .chapter:       .hour
        case .transcription: .minute
        }
    }

    /// The duration of one bucket at this scope, in seconds (approximate).
    var bucketDuration: TimeInterval {
        switch self {
        case .book:          86400
        case .chapter:       3600
        case .transcription: 60
        }
    }

    /// Group cards into time buckets at this scope.
    func group(_ cards: [ContentCard], calendar: Calendar = .current) -> [TimelineGroup] {
        guard !cards.isEmpty else { return [] }
        var groups: [Date: [ContentCard]] = [:]
        for card in cards {
            let bucket = calendar.date(
                bySetting: calendarComponent,
                value: calendar.component(calendarComponent, from: card.realTimestamp),
                of: card.realTimestamp
            ) ?? card.realTimestamp
            groups[bucket, default: []].append(card)
        }
        return groups
            .map { TimelineGroup(timestamp: $0.key, cards: $0.value) }
            .sorted { $0.timestamp < $1.timestamp }
    }

    /// Format a timestamp for display at this scope.
    func format(_ date: Date) -> String {
        switch self {
        case .book:          return date.formatted(.dateTime.month(.abbreviated).day())
        case .chapter:       return date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.defaultDigits)) + ":00"
        case .transcription: return date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
        }
    }
}

extension TimelineScope {
    /// Whether this zoom level should show individual entries (transcripts,
    /// bookmarks, etc.) nested under chapter sections.
    var showsEntries: Bool {
        switch self {
        case .book:          false
        case .chapter:       true
        case .transcription: true
        }
    }
}
