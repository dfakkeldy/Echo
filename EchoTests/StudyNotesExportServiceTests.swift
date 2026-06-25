// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
import ZIPFoundation

@testable import Echo

struct StudyNotesExportServiceTests {
    @Test func exportWritesMarkdownAndCopiesReferencedAssets() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "study-notes-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        let source = root.appending(path: "source", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let memo = source.appending(path: "memo.m4a", directoryHint: .notDirectory)
        let photo = source.appending(path: "page photo.jpg", directoryHint: .notDirectory)
        let cardMedia = source.appending(path: "diagram.png", directoryHint: .notDirectory)
        try Data("voice".utf8).write(to: memo)
        try Data("photo".utf8).write(to: photo)
        try Data("diagram".utf8).write(to: cardMedia)

        let service = StudyNotesExportService()
        let folder = try service.export(
            bookID: "book-1",
            bookTitle: "Deep Work",
            sourceFolderURL: source,
            bookmarks: [
                Bookmark(
                    title: "Attention",
                    timestamp: 75,
                    note: "Protect the morning",
                    voiceMemoFileName: "memo.m4a",
                    bookmarkImageFileName: "page photo.jpg"
                )
            ],
            notes: [
                .init(text: "A later note", timestamp: 180, createdAt: "2026-06-25T12:00:00Z"),
                .init(text: "First note", timestamp: 30, createdAt: "2026-06-25T11:00:00Z"),
            ],
            flashcards: [
                .init(
                    front: "What [matters]?",
                    back: "Depth",
                    timestamp: 45,
                    endTimestamp: nil,
                    tags: "focus book",
                    media: ["diagram.png": cardMedia],
                    createdAt: "2026-06-25T13:00:00Z"
                )
            ],
            chapters: [
                .init(title: "Getting Started", startSeconds: 0),
                .init(title: "Deep Habits", startSeconds: 3661),
            ]
        )

        let markdownURL = folder.appending(path: "Deep Work.md", directoryHint: .notDirectory)
        let markdown = try String(contentsOf: markdownURL, encoding: .utf8)

        #expect(markdown.contains("# Deep Work"))
        #expect(markdown.contains("- **Attention** 01:15"))
        #expect(markdown.contains("Voice Memo: [memo.m4a](assets/memo.m4a)"))
        #expect(markdown.contains("Photo: [page photo.jpg](assets/page%20photo.jpg)"))
        #expect(markdown.contains("- 00:30: First note"))
        #expect(markdown.contains("- **Q:** What \\[matters\\]? 00:45"))
        #expect(markdown.contains("  - Tags: focus book"))
        #expect(markdown.contains("  - Media: [diagram.png](assets/diagram.png)"))
        #expect(markdown.contains("- 1:01:01 - Deep Habits"))

        let assets = folder.appending(path: "assets", directoryHint: .isDirectory)
        #expect(try Data(contentsOf: assets.appending(path: "memo.m4a")) == Data("voice".utf8))
        #expect(try Data(contentsOf: assets.appending(path: "page photo.jpg")) == Data("photo".utf8))
        #expect(try Data(contentsOf: assets.appending(path: "diagram.png")) == Data("diagram".utf8))
    }

    @Test func exportArchiveCreatesShareableZip() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "study-notes-archive-\(UUID().uuidString)", directoryHint: .isDirectory)
        let source = root.appending(path: "source", directoryHint: .isDirectory)
        let unzip = root.appending(path: "unzipped", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let memo = source.appending(path: "memo.m4a", directoryHint: .notDirectory)
        try Data("voice".utf8).write(to: memo)

        let archive = try StudyNotesExportService().exportArchive(
            bookID: "book-1",
            bookTitle: "Archive Book",
            sourceFolderURL: source,
            bookmarks: [
                Bookmark(title: "Keep this", timestamp: 12, voiceMemoFileName: "memo.m4a")
            ],
            notes: [],
            flashcards: [],
            chapters: []
        )

        #expect(archive.pathExtension == "zip")
        try FileManager.default.unzipItem(at: archive, to: unzip)

        let markdownURL = try #require(findFile(named: "Archive Book.md", under: unzip))
        let markdown = try String(contentsOf: markdownURL, encoding: .utf8)
        #expect(markdown.contains("# Archive Book"))
        #expect(markdown.contains("Voice Memo"))

        let memoURL = try #require(findFile(named: "memo.m4a", under: unzip))
        #expect(try Data(contentsOf: memoURL) == Data("voice".utf8))
    }

    @Test func exportAllArchiveCreatesShareableZipWithEveryBook() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "study-notes-all-\(UUID().uuidString)", directoryHint: .isDirectory)
        let source = root.appending(path: "source", directoryHint: .isDirectory)
        let unzip = root.appending(path: "unzipped", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let memo = source.appending(path: "memo.m4a", directoryHint: .notDirectory)
        try Data("voice".utf8).write(to: memo)

        let archive = try StudyNotesExportService().exportAllArchive(
            books: [
                .init(id: "book-1", title: "Same Title", sourceFolderURL: source),
                .init(id: "book-2", title: "Same Title"),
            ],
            bookmarkProvider: { id in
                id == "book-1"
                    ? [Bookmark(title: "First", timestamp: 10, voiceMemoFileName: "memo.m4a")]
                    : [Bookmark(title: "Second", timestamp: 20)]
            },
            noteProvider: { id in
                [
                    .init(
                        text: "Note for \(id)",
                        timestamp: nil,
                        createdAt: "2026-06-25T12:00:00Z"),
                ]
            },
            flashcardProvider: { _ in [] },
            chapterProvider: { _ in [] }
        )

        #expect(archive.pathExtension == "zip")
        try FileManager.default.unzipItem(at: archive, to: unzip)

        let markdownFiles = findFiles(named: "Same Title.md", under: unzip)
        #expect(markdownFiles.count == 2)
        #expect(Set(markdownFiles.map { $0.deletingLastPathComponent().lastPathComponent }).count == 2)

        let combinedMarkdown = try markdownFiles
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        #expect(combinedMarkdown.contains("First"))
        #expect(combinedMarkdown.contains("Second"))
        #expect(combinedMarkdown.contains("Note for book-1"))
        #expect(combinedMarkdown.contains("Note for book-2"))

        let memoURL = try #require(findFile(named: "memo.m4a", under: unzip))
        #expect(try Data(contentsOf: memoURL) == Data("voice".utf8))
    }

    private func findFile(named name: String, under root: URL) -> URL? {
        findFiles(named: name, under: root).first
    }

    private func findFiles(named name: String, under root: URL) -> [URL] {
        FileManager.default
            .enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.lastPathComponent == name }
            ?? []
    }
}
