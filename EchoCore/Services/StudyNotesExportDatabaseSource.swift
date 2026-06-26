// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

struct StudyNotesExportDatabaseSource {
    let databaseWriter: DatabaseWriter

    func books() throws -> [StudyNotesExportService.Book] {
        try AudiobookDAO(db: databaseWriter)
            .all()
            .map {
                StudyNotesExportService.Book(
                    id: $0.id,
                    title: $0.title,
                    sourceFolderURL: URL(string: $0.id)
                )
            }
    }

    func bookmarks(for audiobookID: String) throws -> [Bookmark] {
        try BookmarkDAO(db: databaseWriter)
            .bookmarks(for: audiobookID)
            .map { try $0.toModel() }
    }

    func notes(for audiobookID: String) throws -> [StudyNotesExportService.Note] {
        try NoteDAO(db: databaseWriter)
            .notes(for: audiobookID)
            .map {
                StudyNotesExportService.Note(
                    text: $0.text,
                    timestamp: $0.mediaTimestamp,
                    createdAt: $0.createdAt
                )
            }
    }

    func cards(for audiobookID: String) throws -> [StudyNotesExportService.Card] {
        try FlashcardDAO(db: databaseWriter)
            .flashcards(for: audiobookID)
            .map {
                StudyNotesExportService.Card(
                    front: $0.frontText,
                    back: $0.backText,
                    timestamp: $0.mediaTimestamp,
                    endTimestamp: $0.endTimestamp,
                    tags: $0.tags,
                    media: mediaURLs(from: $0.mediaJSON),
                    createdAt: $0.createdAt
                )
            }
    }

    func chapters(for audiobookID: String) throws -> [StudyNotesExportService.ChapterEntry] {
        try ChapterDAO(db: databaseWriter)
            .chapters(for: audiobookID)
            .map {
                StudyNotesExportService.ChapterEntry(
                    title: $0.title,
                    startSeconds: $0.startSeconds
                )
            }
    }

    func chapters(
        for audiobookID: String,
        fallingBackToDatabaseWhen liveChapters: [Chapter]
    ) throws -> [StudyNotesExportService.ChapterEntry] {
        let mappedLiveChapters = liveChapters.map {
            StudyNotesExportService.ChapterEntry(
                title: $0.title ?? "Chapter \($0.index + 1)",
                startSeconds: $0.startSeconds
            )
        }
        return mappedLiveChapters.isEmpty ? try chapters(for: audiobookID) : mappedLiveChapters
    }

    private func mediaURLs(from json: String?) -> [String: URL] {
        guard let json, let data = json.data(using: .utf8),
            let entries = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            return [:]
        }

        return entries.reduce(into: [:]) { result, entry in
            let url =
                entry.value.hasPrefix("file://")
                ? URL(string: entry.value)
                : URL(fileURLWithPath: entry.value)
            if let url, FileManager.default.fileExists(atPath: url.path) {
                result[entry.key] = url
            }
        }
    }
}
