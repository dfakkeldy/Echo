import Foundation

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
        case let (.chapterHeader(a), .chapterHeader(b)):
            return a.title == b.title && a.chapterIndex == b.chapterIndex
        case let (.block(a), .block(b)):
            return a.id == b.id && a.sequenceIndex == b.sequenceIndex
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
            hasher.combine(block.id)
            hasher.combine(block.sequenceIndex)
        }
    }
}

extension ReaderCardItem: @unchecked Sendable {}
