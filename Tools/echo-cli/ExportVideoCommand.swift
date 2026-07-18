// SPDX-License-Identifier: GPL-3.0-or-later
import ArgumentParser
import Foundation

/// Export a book's Visual Listening slideshow as `<Title>.mp4` +
/// `<Title>.srt` + `<Title>.chapters.txt`.
struct ExportVideoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export-video",
        abstract: "Export a book's slideshow as mp4 + srt + chapters.txt.")

    @Option(help: "Path to the Echo SQLite database.")
    var db: String
    @Option(name: .customLong("audiobook-id"), help: "Audiobook id in the database.")
    var audiobookID: String
    @Option(help: "Book title used for output filenames and metadata fallback.")
    var title: String
    @Option(help: "Output directory for the three files.")
    var out: String
    @Option(
        name: .customLong("cache-dir"),
        help: "Narration cache directory (required for narrated books).")
    var cacheDir: String?
    @Flag(help: "Per-sentence frames instead of word karaoke (faster, smaller).")
    var simple = false
    @Option(help: "Output size as WxH.")
    var size: String = "1920x1080"
    @Option(help: "Optional clip range in seconds, as start-end (e.g. 60-120).")
    var range: String?

    @MainActor func run() async throws {
        let database = try DatabaseService(databaseURL: URL(fileURLWithPath: db))

        let narrated = ExportSourceResolver.isNarrated(
            audiobookID: audiobookID, databaseWriter: database.writer)
        guard !narrated || cacheDir != nil else {
            throw ValidationError("This book is narrated; pass --cache-dir <narration cache>.")
        }

        let dimensions = size.split(separator: "x").compactMap { Int($0) }
        guard dimensions.count == 2 else {
            throw ValidationError("--size must look like 1920x1080")
        }
        var clip: Range<TimeInterval>?
        if let range {
            let parts = range.split(separator: "-").compactMap { TimeInterval($0) }
            guard parts.count == 2, parts[1] > parts[0] else {
                throw ValidationError("--range must look like start-end with end > start")
            }
            clip = parts[0]..<parts[1]
        }

        let outDir = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let output = try await VideoExportService().exportVideo(
            audiobookID: audiobookID,
            bookTitle: title,
            databaseWriter: database.writer,
            cacheDirectory: URL(fileURLWithPath: cacheDir ?? "/nonexistent-cache"),
            outputDirectory: outDir,
            mode: simple ? .simple : .karaoke,
            width: dimensions[0],
            height: dimensions[1],
            range: clip,
            onProgress: { fraction in
                FileHandle.standardError.write(
                    Data(String(format: "\rprogress %3.0f%%", fraction * 100).utf8))
            })
        print("\nVIDEO_DONE \(output.videoURL.path)")
        print("SRT \(output.srtURL.path)")
        print("CHAPTERS \(output.chaptersURL.path)")
    }
}
