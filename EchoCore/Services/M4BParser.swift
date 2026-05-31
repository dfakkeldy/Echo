import Foundation
import AVFoundation

/// Scans a folder for multiple .m4b files, parses each one's metadata and chapters,
/// and builds an aggregated chapter list with cumulative time offsets across all books.
struct M4BParser {

    /// The result of parsing a multi-M4B folder.
    struct ParsedFolder {
        let books: [M4BBook]
        let aggregatedChapters: [AggregatedChapter]
        let totalDuration: TimeInterval
    }

    /// Parses all .m4b files in the given folder and produces an aggregated chapter list.
    /// Returns nil if fewer than 2 .m4b files are found — caller should fall back to flat track behavior.
    static func parseFolder(_ folderURL: URL) async -> ParsedFolder? {
        let m4bFiles = m4bFiles(in: folderURL)
        guard m4bFiles.count >= 2 else { return nil }

        var books: [M4BBook] = []
        for url in m4bFiles {
            if let book = await book(from: url) {
                books.append(book)
            }
        }
        guard books.count >= 2 else { return nil }

        // Sort by natural filename order so "Book 01" < "Book 2" < "Book 10".
        books.sort { $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending }

        // Compute cumulative offsets.
        var cumOffset: TimeInterval = 0
        for i in 0..<books.count {
            books[i].cumulativeStartOffset = cumOffset
            books[i].trackIndex = i
            cumOffset += books[i].duration
        }
        let totalDuration = cumOffset

        // Build aggregated chapters.
        var aggregated: [AggregatedChapter] = []
        for (bookIdx, book) in books.enumerated() {
            for (chapterIdx, chapter) in book.chapters.enumerated() {
                aggregated.append(AggregatedChapter(
                    bookTitle: book.title,
                    bookIndex: bookIdx,
                    chapterTitle: chapter.title ?? String(localized: "Chapter \(chapter.index + 1)"),
                    chapterIndex: chapterIdx,
                    startSeconds: book.cumulativeStartOffset + chapter.startSeconds,
                    endSeconds: book.cumulativeStartOffset + chapter.endSeconds,
                    sourceBookURL: book.url
                ))
            }
        }

        return ParsedFolder(books: books, aggregatedChapters: aggregated, totalDuration: totalDuration)
    }

    // MARK: - Private

    private static func m4bFiles(in folderURL: URL) -> [URL] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folderURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: .skipsHiddenFiles
        ) else { return [] }
        return contents.filter { $0.pathExtension.lowercased() == "m4b" }
    }

    private static func book(from url: URL) async -> M4BBook? {
        let asset = AVURLAsset(url: url)
        let chapters = await ChapterService.parseChapters(from: asset)
        let title = url.deletingPathExtension().lastPathComponent

        let duration: TimeInterval
        do {
            let cmDuration = try await asset.load(.duration)
            duration = cmDuration.seconds.isFinite ? cmDuration.seconds : 0
        } catch {
            duration = 0
        }

        return M4BBook(url: url, title: title, duration: duration, chapters: chapters)
    }
}
