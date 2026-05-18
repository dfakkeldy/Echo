import ArgumentParser
import Foundation
import OrbitEPUBAligner

struct AlignCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "align",
        abstract: "Align a Whisper transcript with an EPUB to produce an Enhanced Sync Map.",
        discussion: """
            Takes a Whisper transcript JSON (from the transcribe subcommand) and an EPUB file,
            then outputs an enhanced transcript with structural markers (chapters, images,
            formatting) injected at the correct audio timestamps.
            """
    )

    @Option(help: "Path to the .epub file")
    var epub: String

    @Option(help: "Path to the transcript JSON (output from the transcribe subcommand)")
    var transcript: String

    @Option(help: "Output path for the enhanced JSON. Defaults to <transcript_stem>.enhanced.json")
    var output: String?

    @Option(help: "Minimum sentence similarity to lock a match (0.0–1.0)")
    var confidence: Double = 0.80

    @Option(help: "Sentence window size for the sliding aligner")
    var maxWindow: Int = 10

    @Flag(help: "Emit per-sentence alignment diagnostics to stderr")
    var verbose: Bool = false

    mutating func run() async throws {
        let outputURL: URL
        if let output {
            outputURL = URL(fileURLWithPath: output)
        } else {
            let transcriptURL = URL(fileURLWithPath: transcript)
            let stem = transcriptURL.deletingPathExtension().lastPathComponent
            outputURL = transcriptURL
                .deletingLastPathComponent()
                .appendingPathComponent("\(stem).enhanced.json")
        }

        guard FileManager.default.fileExists(atPath: epub) else {
            throw ValidationError("EPUB file not found: \(epub)")
        }
        guard FileManager.default.fileExists(atPath: transcript) else {
            throw ValidationError("Transcript file not found: \(transcript)")
        }

        if verbose {
            fputs("EPUB: \(epub)\nTranscript: \(transcript)\nOutput: \(outputURL.path)\n", stderr)
            fputs("Confidence threshold: \(confidence), window: \(maxWindow)\n", stderr)
        }

        let aligner = SlidingWindowAligner(
            sentenceConfidenceThreshold: confidence,
            windowSize: maxWindow
        )
        let pipeline = EPUBAlignmentPipeline(aligner: aligner)

        if verbose {
            fputs("Starting alignment pipeline...\n", stderr)
        }

        let enhanced = try await pipeline.process(
            epubPath: epub,
            transcriptPath: transcript
        )

        if verbose {
            fputs("Alignment complete. \(enhanced.count) segments produced.\n", stderr)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(enhanced)
        try data.write(to: outputURL)

        print("Enhanced transcript written to: \(outputURL.path)")
        print("Segments: \(enhanced.count)")
    }
}
