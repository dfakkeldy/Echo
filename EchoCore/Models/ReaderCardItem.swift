// SPDX-License-Identifier: GPL-3.0-or-later
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
    /// A bookmark threaded inline at its chapter position.
    case bookmark(BookmarkRecord)
    /// An Anki/study flashcard threaded inline at its source-block (or timestamp) position.
    case ankiCard(Flashcard)
    /// A free-text note threaded into the feed at its EPUB block position.
    case note(NoteRecord)
    /// A standalone voice memo threaded into the feed at its EPUB block position.
    case voiceMemo(VoiceMemoRecord)

    var id: String {
        switch self {
        case .chapterHeader(_, let chapterIndex):
            return "ch-\(chapterIndex)"
        case .block(let block):
            return "b-\(block.id)"
        case .bookmark(let record):
            return "bm-\(record.id)"
        case .ankiCard(let card):
            return "fc-\(card.id)"
        case .note(let note):
            return "note-\(note.id)"
        case .voiceMemo(let memo):
            return "vm-\(memo.id)"
        }
    }
}

extension ReaderCardItem: Hashable {
    nonisolated static func == (lhs: ReaderCardItem, rhs: ReaderCardItem) -> Bool {
        switch (lhs, rhs) {
        case (.chapterHeader(let a1, let a2), .chapterHeader(let b1, let b2)):
            return a1 == b1 && a2 == b2
        case (.block(let a), .block(let b)):
            return a == b
        case (.bookmark(let a), .bookmark(let b)):
            return a.id == b.id && a.modifiedAt == b.modifiedAt
        case (.ankiCard(let a), .ankiCard(let b)):
            return a.id == b.id && a.modifiedAt == b.modifiedAt
        case (.note(let a), .note(let b)):
            return a == b
        case (.voiceMemo(let a), .voiceMemo(let b)):
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
        case .bookmark(let record):
            hasher.combine(2)
            hasher.combine(record.id)
            hasher.combine(record.modifiedAt)
        case .ankiCard(let card):
            hasher.combine(3)
            hasher.combine(card.id)
            hasher.combine(card.modifiedAt)
        case .note(let note):
            hasher.combine(4)
            hasher.combine(note)
        case .voiceMemo(let memo):
            hasher.combine(5)
            hasher.combine(memo)
        }
    }
}

extension ReaderCardItem: Sendable {}
