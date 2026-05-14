import ArgumentParser
import Foundation
import WhisperKit

@main
struct OrbitTranscriptionCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Generate .transcript.json sidecar files for Orbit Audiobooks.",
        discussion: """
            Transcribes an audio file using WhisperKit (local CoreML) and writes a
            JSON sidecar matching the TranscriptionSegment Codable schema consumed
            by the Orbit Audiobooks iOS and macOS apps.

            The output format is:
              [{"text": "...", "startTime": 1.0, "endTime": 2.5}, ...]

            The first run downloads Whisper model weights from HuggingFace (~500 MB
            for the base model). Subsequent runs use the cached model.
            """
    )

    @Argument(help: "Path to the audio file (.mp3, .m4b, .m4a, .wav, .flac).")
    var audioPath: String

    @Option(help: "Output JSON path. Defaults to <audio_stem>.transcript.json alongside the input.")
    var outputPath: String?

    @Option(help: "Whisper model size.")
    var modelSize: String = "base"

    @Option(help: "Language code for transcription (nil = auto-detect).")
    var language: String?

    mutating func run() async throws {
        let audioURL = URL(fileURLWithPath: audioPath)
        let outputURL: URL
        if let outputPath {
            outputURL = URL(fileURLWithPath: outputPath)
        } else {
            let stem = audioURL.deletingPathExtension().lastPathComponent
            outputURL = audioURL
                .deletingLastPathComponent()
                .appendingPathComponent("\(stem).transcript.json")
        }

        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw ValidationError("Audio file not found: \(audioPath)")
        }

        print("Loading WhisperKit with model '\(modelSize)'...")
        print("(First run downloads ~500 MB from HuggingFace — this may take a few minutes.)")

        let whisperKit = try await WhisperKit(model: modelSize)

        print("Transcribing: \(audioPath)")
        let options = DecodingOptions(
            task: .transcribe,
            language: language ?? "en",
            temperature: 0.0,
            wordTimestamps: false,
            suppressBlank: true,
            chunkingStrategy: .vad
        )

        let results: [TranscriptionResult] = try await whisperKit.transcribe(
            audioPath: audioPath,
            decodeOptions: options
        )

        var segments: [TranscriptionSegment] = []
        for result in results {
            for segment in result.segments {
                segments.append(TranscriptionSegment(
                    text: segment.text.trimmingCharacters(in: .whitespaces),
                    startTime: TimeInterval(segment.start),
                    endTime: TimeInterval(segment.end)
                ))
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(segments)
        try data.write(to: outputURL)

        print("Wrote \(segments.count) segments to: \(outputURL.path)")
    }
}

/// Mirrors the Codable schema of the iOS app's TranscriptionSegment.
/// Only stored properties are encoded — computed properties (like `id`
/// in the iOS app) are not part of the JSON wire format.
struct TranscriptionSegment: Codable {
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
}
