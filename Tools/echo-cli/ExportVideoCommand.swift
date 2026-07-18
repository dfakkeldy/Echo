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

        let dimensionParts = size.split(separator: "x", omittingEmptySubsequences: false)
        guard
            dimensionParts.count == 2,
            let width = Int(dimensionParts[0]),
            let height = Int(dimensionParts[1]),
            width > 0,
            height > 0
        else {
            throw ValidationError("--size must look like 1920x1080")
        }
        var clip: Range<TimeInterval>?
        if let range {
            let parts = range.split(separator: "-", omittingEmptySubsequences: false)
            guard
                parts.count == 2,
                let start = TimeInterval(parts[0]),
                let end = TimeInterval(parts[1]),
                start.isFinite,
                end.isFinite,
                start >= 0,
                end > start
            else {
                throw ValidationError("--range must look like start-end with end > start")
            }
            clip = start..<end
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
            width: width,
            height: height,
            range: clip,
            onProgress: { fraction in
                let percent = (fraction * 100).formatted(
                    .number.precision(.fractionLength(0)))
                FileHandle.standardError.write(
                    Data("\rprogress \(percent)%".utf8))
            })
        print("\nVIDEO_DONE \(output.videoURL.path)")
        print("SRT \(output.srtURL.path)")
        print("CHAPTERS \(output.chaptersURL.path)")
    }
}
