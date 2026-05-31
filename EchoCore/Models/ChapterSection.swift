import Foundation

/// Groups ContentCards by chapter boundaries for the hierarchical playlist timeline.
struct ChapterSection: Identifiable, Equatable, Sendable {
    let index: Int
    let title: String
    let startSeconds: TimeInterval
    let endSeconds: TimeInterval
    let cards: [ContentCard]
    let totalBookDuration: TimeInterval

    var id: Int { index }
    var duration: TimeInterval { endSeconds - startSeconds }
}
