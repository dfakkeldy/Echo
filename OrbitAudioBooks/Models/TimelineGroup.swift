import Foundation

struct TimelineGroup: Identifiable, Equatable {
    let id: String
    let timestamp: Date
    let cards: [ContentCard]

    init(timestamp: Date, cards: [ContentCard]) {
        self.id = timestamp.ISO8601Format()
        self.timestamp = timestamp
        self.cards = cards
    }
}
