import Foundation

struct TimelineGroup: Identifiable, Equatable, Sendable {
    let id: String
    let timestamp: Date
    let cards: [ContentCard]

    init(timestamp: Date, cards: [ContentCard]) {
        // Include fractional seconds to prevent ID collisions when two groups
        // share the same whole-second timestamp.
        self.id = timestamp.ISO8601Format(.iso8601(timeZone: .current, includingFractionalSeconds: true))
        self.timestamp = timestamp
        self.cards = cards
    }
}
