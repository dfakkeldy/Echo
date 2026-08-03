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
    @Option(help: "Output size as WxH, e.g. 1920x1080. Defaults to landscape.")
    var size: String?
    @Flag(help: "Export a 1080x1920 phone-portrait video.")
    var portrait = false
    @Option(help: "Optional clip range in seconds, as start-end (e.g. 60-120).")
    var range: String?

    @MainActor func run() async throws {
        let dimensions: SlideshowVideoDimensions
        do {
            dimensions = try SlideshowVideoDimensionRequest.resolve(portrait: portrait, size: size)
        } catch SlideshowVideoDimensionRequestError.conflictingOptions {
            throw ValidationError(
                "--portrait cannot be used with --size; choose one format option.")
        } catch let error as SlideshowVideoDimensionError {
            // `error.errorDescription` resolves via `String(localized:)` against
            // EchoCore/Localizable.xcstrings, but the echo-cli target doesn't
            // resolve that catalog at runtime -- it surfaces the raw key (e.g.
            // "videoExportErrorOddDimensions") instead of the English text.
            // Map each case to the approved spec string explicitly so the CLI
            // always prints actionable copy regardless of catalog resolution.
            let message: String
            switch error {
            case .malformedSize:
                message = "--size must look like 1920x1080."
            case .nonPositive:
                message = "Video width and height must both be positive."
            case .odd:
                message = "Video width and height must both be even for H.264."
            case .shortestSideTooSmall:
                message = "Video's shortest side must be at least 180 pixels."
            case .longestSideTooLarge:
                message = "Video's longest side must be no more than 4096 pixels."
            case .pixelAreaTooLarge:
                message = "Video dimensions exceed the maximum 8,847,360-pixel area."
            case .aspectRatioTooExtreme:
                message = "Video aspect ratio must not exceed 4:1."
            }
            throw ValidationError(message)
        }

        let database = try DatabaseService(databaseURL: URL(fileURLWithPath: db))

        let narrated = ExportSourceResolver.isNarrated(
            audiobookID: audiobookID, databaseWriter: database.writer)
        guard !narrated || cacheDir != nil else {
            throw ValidationError("This book is narrated; pass --cache-dir <narration cache>.")
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
            preferredVoice: VoiceCatalog.default.id,
            outputDirectory: outDir,
            mode: simple ? .simple : .karaoke,
            dimensions: dimensions,
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
