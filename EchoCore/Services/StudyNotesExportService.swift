// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import ZIPFoundation

/// Generates an Obsidian-compatible Markdown study-notes bundle per book.
/// Output: `BookTitle/BookTitle.md` + `assets/` directory with media files.
struct StudyNotesExportService {
    struct Book: Equatable {
        var id: String
        var title: String
        var sourceFolderURL: URL?

        init(id: String, title: String, sourceFolderURL: URL? = nil) {
            self.id = id
            self.title = title
            self.sourceFolderURL = sourceFolderURL
        }
    }

    struct Note: Equatable {
        var text: String
        var timestamp: TimeInterval?
        var createdAt: String
    }

    struct Card: Equatable {
        var front: String
        var back: String
        var timestamp: TimeInterval?
        var endTimestamp: TimeInterval?
        var tags: String?
        var media: [String: URL]
        var createdAt: String?
    }

    struct ChapterEntry: Equatable {
        var title: String
        var startSeconds: TimeInterval
    }

    /// Exports study notes for one book to a temporary directory.
    /// - Returns: URL of the generated folder.
    func export(
        bookID: String,
        bookTitle: String,
        sourceFolderURL: URL? = nil,
        bookmarks: [Bookmark],
        notes: [Note],
        flashcards: [Card],
        chapters: [ChapterEntry]
    ) throws -> URL {
        let folderName = sanitize(bookTitle)
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: folderName, directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: tmp)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let assets = tmp.appending(path: "assets", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

        var md = """
        # \(inlineMarkdown(bookTitle))

        """

        // MARK: Bookmarks
        if !bookmarks.isEmpty {
            md += "## Bookmarks\n\n"
            for bm in bookmarks.sorted(by: { $0.timestamp < $1.timestamp }) {
                let ts = formatHMS(bm.timestamp)
                md += "- **\(inlineMarkdown(bm.title))** \(ts)\n"
                if let note = bm.note, !note.isEmpty {
                    md += "  - \(inlineMarkdown(note))\n"
                }
                if let voice = bm.voiceMemoFileName {
                    if let copied = try copyAsset(
                        named: voice, from: bm.voiceMemoURL(in: sourceFolderURL), into: assets)
                    {
                        md += "  - Voice Memo: \(assetLink(label: voice, assetName: copied))\n"
                    }
                }
                if let image = bm.bookmarkImageFileName {
                    if let copied = try copyAsset(
                        named: image, from: bm.bookmarkImageURL(in: sourceFolderURL), into: assets)
                    {
                        md += "  - Photo: \(assetLink(label: image, assetName: copied))\n"
                    }
                }
            }
            md += "\n"
        }

        // MARK: Notes
        if !notes.isEmpty {
            md += "## Notes\n\n"
            for note in notes.sorted(by: compareTimestampThenCreatedAt) {
                if let ts = note.timestamp {
                    md += "- \(formatHMS(ts)): \(inlineMarkdown(note.text))\n"
                } else {
                    md += "- \(inlineMarkdown(note.text))\n"
                }
            }
            md += "\n"
        }

        // MARK: Flashcards
        if !flashcards.isEmpty {
            md += "## Flashcards\n\n"
            for card in flashcards.sorted(by: compareTimestampThenCreatedAt) {
                let timestamp = card.timestamp.map { " \(formatHMS($0))" } ?? ""
                md += "- **Q:** \(inlineMarkdown(card.front))\(timestamp)\n"
                md += "  - **A:** \(inlineMarkdown(card.back))\n"
                if let tags = card.tags?.trimmingCharacters(in: .whitespacesAndNewlines),
                    !tags.isEmpty
                {
                    md += "  - Tags: \(inlineMarkdown(tags))\n"
                }
                for (name, url) in card.media.sorted(by: { $0.key < $1.key }) {
                    if let copied = try copyAsset(named: name, from: url, into: assets) {
                        md += "  - Media: \(assetLink(label: name, assetName: copied))\n"
                    }
                }
            }
            md += "\n"
        }

        // MARK: Chapters
        if !chapters.isEmpty {
            md += "## Chapters\n\n"
            for ch in chapters.sorted(by: { $0.startSeconds < $1.startSeconds }) {
                md += "- \(formatHMS(ch.startSeconds)) - \(inlineMarkdown(ch.title))\n"
            }
            md += "\n"
        }

        let mdFile = tmp.appending(path: "\(folderName).md", directoryHint: .notDirectory)
        try md.write(to: mdFile, atomically: true, encoding: .utf8)
        return tmp
    }

    /// Exports study notes and returns a `.zip` suitable for `ShareLink`.
    func exportArchive(
        bookID: String,
        bookTitle: String,
        sourceFolderURL: URL? = nil,
        bookmarks: [Bookmark],
        notes: [Note],
        flashcards: [Card],
        chapters: [ChapterEntry]
    ) throws -> URL {
        let folder = try export(
            bookID: bookID,
            bookTitle: bookTitle,
            sourceFolderURL: sourceFolderURL,
            bookmarks: bookmarks,
            notes: notes,
            flashcards: flashcards,
            chapters: chapters
        )
        let archive = FileManager.default.temporaryDirectory
            .appending(path: "\(sanitize(bookTitle)).zip", directoryHint: .notDirectory)
        try? FileManager.default.removeItem(at: archive)
        try FileManager.default.zipItem(at: folder, to: archive)
        return archive
    }

    /// Exports all books in bulk, returning a single zip-ready folder.
    func exportAll(
        books: [(id: String, title: String)],
        bookmarkProvider: (String) -> [Bookmark],
        noteProvider: (String) -> [Note],
        flashcardProvider: (String) -> [Card],
        chapterProvider: (String) -> [ChapterEntry]
    ) throws -> URL {
        try exportAll(
            books: books.map { Book(id: $0.id, title: $0.title) },
            bookmarkProvider: bookmarkProvider,
            noteProvider: noteProvider,
            flashcardProvider: flashcardProvider,
            chapterProvider: chapterProvider
        )
    }

    /// Exports all books in bulk, returning a single zip-ready folder.
    func exportAll(
        books: [Book],
        bookmarkProvider: (String) -> [Bookmark],
        noteProvider: (String) -> [Note],
        flashcardProvider: (String) -> [Card],
        chapterProvider: (String) -> [ChapterEntry]
    ) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appending(
                path: "Echo_Study_Notes_\(Date.now.ISO8601Format().prefix(10))",
                directoryHint: .isDirectory
            )
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
                sourceFolderURL: book.sourceFolderURL,
                bookmarks: bm,
                notes: notes,
                flashcards: cards,
                chapters: chapters
            )

            let dest = uniqueDirectoryURL(named: sanitize(book.title), in: tmp)
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: bookFolder, to: dest)
        }

        return tmp
    }

    /// Exports all books and returns a single shareable `.zip`.
    func exportAllArchive(
        books: [Book],
        bookmarkProvider: (String) -> [Bookmark],
        noteProvider: (String) -> [Note],
        flashcardProvider: (String) -> [Card],
        chapterProvider: (String) -> [ChapterEntry]
    ) throws -> URL {
        let folder = try exportAll(
            books: books,
            bookmarkProvider: bookmarkProvider,
            noteProvider: noteProvider,
            flashcardProvider: flashcardProvider,
            chapterProvider: chapterProvider
        )
        let archive = FileManager.default.temporaryDirectory
            .appending(path: "\(folder.lastPathComponent).zip", directoryHint: .notDirectory)
        try? FileManager.default.removeItem(at: archive)
        try FileManager.default.zipItem(at: folder, to: archive)
        return archive
    }

    // MARK: - Helpers

    private func sanitize(_ name: String) -> String {
        SafeFileName.sanitizeForFilename(name)
    }

    private func copyAsset(named name: String, from source: URL?, into assets: URL) throws
        -> String?
    {
        guard let source, FileManager.default.fileExists(atPath: source.path) else {
            return nil
        }
        let safeName = sanitize(name.isEmpty ? source.lastPathComponent : name)
        let destination = uniqueAssetURL(named: safeName, in: assets)
        try FileManager.default.copyItem(at: source, to: destination)
        return destination.lastPathComponent
    }

    private func uniqueAssetURL(named name: String, in assets: URL) -> URL {
        let fallback = name.isEmpty ? "asset" : name
        var candidate = assets.appending(path: fallback, directoryHint: .notDirectory)
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            return candidate
        }

        let original = URL(fileURLWithPath: fallback)
        let base = original.deletingPathExtension().lastPathComponent
        let ext = original.pathExtension
        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let filename = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            candidate = assets.appending(path: filename, directoryHint: .notDirectory)
            index += 1
        }
        return candidate
    }

    private func uniqueDirectoryURL(named name: String, in parent: URL) -> URL {
        let fallback = name.isEmpty ? "Book" : name
        var candidate = parent.appending(path: fallback, directoryHint: .isDirectory)
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            return candidate
        }

        var index = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = parent.appending(path: "\(fallback)-\(index)", directoryHint: .isDirectory)
            index += 1
        }
        return candidate
    }

    private func assetLink(label: String, assetName: String) -> String {
        let encodedName = assetName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed)
            ?? assetName
        return "[\(inlineMarkdown(label))](assets/\(encodedName))"
    }

    private func inlineMarkdown(_ text: String) -> String {
        text
            .replacing("\\", with: "\\\\")
            .replacing("[", with: "\\[")
            .replacing("]", with: "\\]")
            .replacing("\n", with: " ")
    }

    private func compareTimestampThenCreatedAt(_ lhs: Note, _ rhs: Note) -> Bool {
        switch (lhs.timestamp, rhs.timestamp) {
        case let (left?, right?) where left != right:
            return left < right
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            return lhs.createdAt < rhs.createdAt
        }
    }

    private func compareTimestampThenCreatedAt(_ lhs: Card, _ rhs: Card) -> Bool {
        switch (lhs.timestamp, rhs.timestamp) {
        case let (left?, right?) where left != right:
            return left < right
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        default:
            return (lhs.createdAt ?? "") < (rhs.createdAt ?? "")
        }
    }
}
