import Foundation

enum TimeScale: String, CaseIterable, Identifiable {
    case seconds
    case minutes
    case hours
    case days

    var id: String { rawValue }

    var label: String {
        switch self {
        case .seconds: String(localized: "Sec")
        case .minutes: String(localized: "Min")
        case .hours:   String(localized: "Hr")
        case .days:    String(localized: "Day")
        }
    }

    var menuLabel: String {
        switch self {
        case .seconds: String(localized: "Seconds")
        case .minutes: String(localized: "Minutes")
        case .hours:   String(localized: "Hours")
        case .days:    String(localized: "Days")
        }
    }

    var calendarComponent: Calendar.Component {
        switch self {
        case .seconds: .second
        case .minutes: .minute
        case .hours:   .hour
        case .days:    .day
        }
    }

    /// The duration of one bucket at this scale, in seconds (approximate).
    var bucketDuration: TimeInterval {
        switch self {
        case .seconds: 1
        case .minutes: 60
        case .hours:   3600
        case .days:    86400
        }
    }

    /// Group cards into time buckets at this scale.
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

    /// Format a timestamp for display at this scale.
    func format(_ date: Date) -> String {
        let fmt = DateFormatter()
        switch self {
        case .seconds: fmt.dateFormat = "HH:mm:ss"
        case .minutes: fmt.dateFormat = "HH:mm"
        case .hours:   fmt.dateFormat = "HH:00"
        case .days:    fmt.dateFormat = "MMM d"
        }
        return fmt.string(from: date)
    }
}

extension TimeScale {
    /// Whether this zoom level should show individual entries (transcripts,
    /// bookmarks, etc.) nested under chapter sections.
    var showsEntries: Bool {
        switch self {
        case .seconds, .minutes: return true
        case .hours, .days: return false
        }
    }
}
