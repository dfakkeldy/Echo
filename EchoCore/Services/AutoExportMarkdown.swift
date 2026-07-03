// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation

/// Deterministic Markdown rendering for auto-export mirror files.
nonisolated enum AutoExportMarkdown {
    struct BookContext: Equatable {
        var id: String
        var title: String
        var author: String?
        var chapters: [StudyNotesExportService.ChapterEntry]
    }

    static func bookKey(bookID: String) -> String {
        String(sha256Hex(bookID).prefix(8))
    }

    static func fileName(bookID: String, title: String) -> String {
        let base = SafeFileName.sanitizeForFilename(title)
        let stem = base.isEmpty ? "Book" : base
        return "\(stem)-\(bookKey(bookID: bookID)).md"
    }

    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .map { byte in
                let hex = String(byte, radix: 16)
                return hex.count == 1 ? "0\(hex)" : hex
            }
            .joined()
    }

    static func render(
        book: BookContext,
        bookmarks: [Bookmark],
        notes: [StudyNotesExportService.Note],
        cards: [StudyNotesExportService.Card]
    ) -> String {
        var markdown = """
        ---
        type: echo-study-export
        version: 1
        book: "\(yaml(book.title))"
        """
        markdown += "\n"
        if let author = book.author, !author.isEmpty {
            markdown += "author: \"\(yaml(author))\"\n"
        }
        markdown += """
        book_key: \(bookKey(bookID: book.id))
        ---

        # \(inline(book.title))

        """

        let sortedBookmarks = bookmarks.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        if !sortedBookmarks.isEmpty {
            markdown += "## Bookmarks\n"
            for bookmark in sortedBookmarks {
                markdown += bookmarkEntry(bookmark, chapters: book.chapters)
            }
        }

        let sortedNotes = notes.sorted { lhs, rhs in
            captureSortPrecedes(
                lhsTimestamp: lhs.timestamp,
                lhsCreatedAt: lhs.createdAt,
                lhsID: lhs.id ?? "",
                rhsTimestamp: rhs.timestamp,
                rhsCreatedAt: rhs.createdAt,
                rhsID: rhs.id ?? ""
            )
        }
        if !sortedNotes.isEmpty {
            markdown += "\n## Notes\n"
            for note in sortedNotes {
                markdown += noteEntry(note, chapters: book.chapters)
            }
        }

        let sortedCards = cards.sorted { lhs, rhs in
            captureSortPrecedes(
                lhsTimestamp: lhs.timestamp,
                lhsCreatedAt: lhs.createdAt ?? "",
                lhsID: lhs.id ?? "",
                rhsTimestamp: rhs.timestamp,
                rhsCreatedAt: rhs.createdAt ?? "",
                rhsID: rhs.id ?? ""
            )
        }
        if !sortedCards.isEmpty {
            markdown += "\n## Flashcards\n"
            for card in sortedCards {
                markdown += cardEntry(card, chapters: book.chapters)
            }
        }

        return markdown
    }

    static func chapterTitle(
        at timestamp: TimeInterval,
        in chapters: [StudyNotesExportService.ChapterEntry]
    ) -> String? {
        chapters
            .filter { $0.startSeconds <= timestamp }
            .max { $0.startSeconds < $1.startSeconds }?
            .title
    }

    private static func bookmarkEntry(
        _ bookmark: Bookmark,
        chapters: [StudyNotesExportService.ChapterEntry]
    ) -> String {
        // Location fields are intentionally omitted from plaintext sync files.
        var entry = "\n<!-- echo:bookmark \(bookmark.id.uuidString) -->\n"
        entry += "### \(formatFixedHMS(bookmark.timestamp)) - \(inline(bookmark.title))\n"
        entry += "- Type: bookmark\n"
        if let chapter = chapterTitle(at: bookmark.timestamp, in: chapters) {
            entry += "- Chapter: \(inline(chapter))\n"
        }
        entry += "- Open in Echo: echoaudio://open/bookmark/\(bookmark.id.uuidString)\n"
        if bookmark.voiceMemoFileName != nil {
            entry += "- Voice memo: attached in Echo (not exported)\n"
        }
        if bookmark.bookmarkImageFileName != nil {
            entry += "- Photo: attached in Echo (not exported)\n"
        }
        if let note = bookmark.note, !note.isEmpty {
            entry += "\n> \(inline(note))\n"
        }
        return entry
    }

    private static func noteEntry(
        _ note: StudyNotesExportService.Note,
        chapters: [StudyNotesExportService.ChapterEntry]
    ) -> String {
        var entry = "\n<!-- echo:note \(note.id ?? "unidentified") -->\n"
        if let timestamp = note.timestamp {
            entry += "### \(formatFixedHMS(timestamp)) - Note\n"
        } else {
            entry += "### Note\n"
        }
        entry += "- Type: note\n"
        if let timestamp = note.timestamp,
            let chapter = chapterTitle(at: timestamp, in: chapters)
        {
            entry += "- Chapter: \(inline(chapter))\n"
        }
        entry += "- Created: \(note.createdAt)\n"
        entry += "\n> \(inline(note.text))\n"
        return entry
    }

    private static func cardEntry(
        _ card: StudyNotesExportService.Card,
        chapters: [StudyNotesExportService.ChapterEntry]
    ) -> String {
        var entry = "\n<!-- echo:card \(card.id ?? "unidentified") -->\n"
        if let timestamp = card.timestamp {
            entry += "### \(formatFixedHMS(timestamp)) - Flashcard\n"
        } else {
            entry += "### Flashcard\n"
        }
        entry += "- Type: flashcard\n"
        if let timestamp = card.timestamp,
            let chapter = chapterTitle(at: timestamp, in: chapters)
        {
            entry += "- Chapter: \(inline(chapter))\n"
        }
        if let createdAt = card.createdAt {
            entry += "- Created: \(createdAt)\n"
        }
        if let tags = card.tags?.trimmingCharacters(in: .whitespacesAndNewlines), !tags.isEmpty {
            entry += "- Tags: \(inline(tags))\n"
        }
        if !card.media.isEmpty {
            let names = card.media.keys.sorted().map(inline).joined(separator: ", ")
            entry += "- Media: \(names) (attached in Echo; not exported)\n"
        }
        entry += "\n**Q:** \(inline(card.front))\n"
        entry += "**A:** \(inline(card.back))\n"
        return entry
    }

    private static func captureSortPrecedes(
        lhsTimestamp: TimeInterval?,
        lhsCreatedAt: String,
        lhsID: String,
        rhsTimestamp: TimeInterval?,
        rhsCreatedAt: String,
        rhsID: String
    ) -> Bool {
        switch (lhsTimestamp, rhsTimestamp) {
        case let (left?, right?) where left != right:
            return left < right
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            if lhsCreatedAt != rhsCreatedAt { return lhsCreatedAt < rhsCreatedAt }
            return lhsID < rhsID
        }
    }

    private static func formatFixedHMS(_ time: TimeInterval) -> String {
        guard time.isFinite, !time.isNaN else { return "00:00:00" }
        let seconds = max(0, Int(time.rounded(.down)))
        return [
            seconds / 3_600,
            (seconds % 3_600) / 60,
            seconds % 60,
        ]
        .map(twoDigitString)
        .joined(separator: ":")
    }

    private static func twoDigitString(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }

    private static func inline(_ text: String) -> String {
        text
            .replacing("\\", with: "\\\\")
            .replacing("[", with: "\\[")
            .replacing("]", with: "\\]")
            .replacing("\n", with: " ")
    }

    private static func yaml(_ text: String) -> String {
        text
            .replacing("\\", with: "\\\\")
            .replacing("\"", with: "\\\"")
            .replacing("\n", with: " ")
    }
}
