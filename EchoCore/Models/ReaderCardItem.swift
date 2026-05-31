import Foundation

/// A section of the EPUB reader feed, containing a heading hierarchy and a list of cards.
struct ReaderCardSection: Identifiable, Hashable, Sendable {
    let id: String
    /// Stack of heading titles (e.g. ["Chapter 1", "Section 1.1"])
    let headingStack: [String]
    let items: [ReaderCardItem]
}

/// Items displayed in the EPUB reader feed.
enum ReaderCardItem {
    /// A divider between chapters showing the chapter title.
    case chapterHeader(title: String, chapterIndex: Int)
    /// An EPUB block (heading, paragraph, or image).
    case block(EPubBlockRecord)
    // Future: case flashcard(Flashcard, associatedBlockIDs: [String], placement: FlashcardPlacement)

    var id: String {
        switch self {
        case .chapterHeader(_, let chapterIndex):
            return "ch-\(chapterIndex)"
        case .block(let block):
            return "b-\(block.id)"
        }
    }
}

extension ReaderCardItem: Hashable {
    nonisolated static func == (lhs: ReaderCardItem, rhs: ReaderCardItem) -> Bool {
        switch (lhs, rhs) {
        case let (.chapterHeader(a1, a2), .chapterHeader(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.block(a), .block(b)):
            return a == b
        default:
            return false
        }
    }

    nonisolated func hash(into hasher: inout Hasher) {
        switch self {
        case .chapterHeader(let title, let chapterIndex):
            hasher.combine(0)
            hasher.combine(title)
            hasher.combine(chapterIndex)
        case .block(let block):
            hasher.combine(1)
            hasher.combine(block)
        }
    }
}

extension ReaderCardItem: @unchecked Sendable {}
