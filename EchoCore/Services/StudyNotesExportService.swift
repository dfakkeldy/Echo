import Foundation

/// Generates an Obsidian-compatible Markdown study-notes bundle per book.
/// Output: `BookTitle/BookTitle.md` + `assets/` directory with media files.
struct StudyNotesExportService {

    /// Exports study notes for one book to a temporary directory.
    /// - Returns: URL of the generated folder (zipped for ShareLink).
    func export(
        bookID: String,
        bookTitle: String,
        bookmarks: [Bookmark],
        notes: [(text: String, timestamp: TimeInterval?, createdAt: String)],
        flashcards: [(front: String, back: String, createdAt: String)],
        chapters: [(title: String, startSeconds: TimeInterval)]
    ) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(sanitize(bookTitle))
        try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let assets = tmp.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

        var md = """
        # \(bookTitle)

        """

        // ── Bookmarks ──
        if !bookmarks.isEmpty {
            md += "## Bookmarks\n\n"
            for bm in bookmarks.sorted(by: { $0.timestamp < $1.timestamp }) {
                let ts = formatTimestamp(bm.timestamp)
                md += "- **\(bm.title)** \(ts)\n"
                if let note = bm.note, !note.isEmpty {
                    md += "  - \(note)\n"
                }
                if let voice = bm.voiceMemoFileName {
                    let dest = assets.appendingPathComponent(voice)
                    if let src = bm.voiceMemoURL(in: nil), FileManager.default.fileExists(atPath: src.path) {
                        try? FileManager.default.copyItem(at: src, to: dest)
                    }
                    md += "  - 🎙️ [Voice Memo](assets/\(voice))\n"
                }
            }
            md += "\n"
        }

        // ── Book Notes ──
        if !notes.isEmpty {
            md += "## Notes\n\n"
            for note in notes {
                if let ts = note.timestamp {
                    md += "- \(formatTimestamp(ts)): \(note.text)\n"
                } else {
                    md += "- \(note.text)\n"
                }
            }
            md += "\n"
        }

        // ── Flashcards ──
        if !flashcards.isEmpty {
            md += "## Flashcards\n\n"
            for card in flashcards {
                md += "- **Q:** \(card.front)\n"
                md += "  - **A:** \(card.back)\n"
            }
            md += "\n"
        }

        // ── Chapters ──
        if !chapters.isEmpty {
            md += "## Chapters\n\n"
            for ch in chapters {
                md += "- \(formatTimestamp(ch.startSeconds)) — \(ch.title)\n"
            }
            md += "\n"
        }

        let mdFile = tmp.appendingPathComponent("\(sanitize(bookTitle)).md")
        try md.write(to: mdFile, atomically: true, encoding: .utf8)
        return tmp
    }

    /// Exports all books in bulk, returning a single zip-ready folder.
    func exportAll(
        books: [(id: String, title: String)],
        bookmarkProvider: (String) -> [Bookmark],
        noteProvider: (String) -> [(text: String, timestamp: TimeInterval?, createdAt: String)],
        flashcardProvider: (String) -> [(front: String, back: String, createdAt: String)],
        chapterProvider: (String) -> [(title: String, startSeconds: TimeInterval)]
    ) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("Echo_Study_Notes_\(Date().ISO8601Format().prefix(10))")
        try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        for book in books {
            let bm = bookmarkProvider(book.id)
            let notes = noteProvider(book.id)
            let cards = flashcardProvider(book.id)
            let chapters = chapterProvider(book.id)

            let bookFolder = try export(
                bookID: book.id,
                bookTitle: book.title,
                bookmarks: bm,
                notes: notes,
                flashcards: cards,
                chapters: chapters
            )

            let dest = tmp.appendingPathComponent(sanitize(book.title))
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: bookFolder, to: dest)
        }

        return tmp
    }

    // MARK: - Helpers

    private func sanitize(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*:|\"<>")
        return name.components(separatedBy: invalid).joined(separator: "_")
            .trimmingCharacters(in: .whitespaces)
    }

    private func formatTimestamp(_ seconds: TimeInterval) -> String {
        let h = Int(seconds) / 3600
        let m = (Int(seconds) % 3600) / 60
        let s = Int(seconds) % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
