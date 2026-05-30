import ArgumentParser
import Foundation
import WhisperKit

struct TranscribeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcribe",
        abstract: "Generate .transcript.json sidecar files for Orbit Audiobooks.",
        discussion: """
            Transcribes an audio file using WhisperKit (local CoreML) and writes a
            JSON sidecar matching the TranscriptionSegment Codable schema consumed
            by the Orbit Audiobooks iOS and macOS apps.
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

    private static let validModelSizes: Set<String> = [
        "tiny", "tiny.en",
        "base", "base.en",
        "small", "small.en",
        "medium", "medium.en",
        "large", "large-v1", "large-v2", "large-v3"
    ]

    mutating func validate() throws {
        let normalized = modelSize.lowercased()
        guard Self.validModelSizes.contains(normalized) else {
            let valid = Self.validModelSizes.sorted().joined(separator: ", ")
            throw ValidationError("""
                Invalid model size '\(modelSize)'. Valid options: \(valid)
                """)
        }
        modelSize = normalized
    }

    mutating func run() async throws {
        do {
            try await runTranscription()
        } catch {
            try? TranscriptionCLIEvent.error(message: error.localizedDescription).emit()
            throw error
        }
    }

    private func runTranscription() async throws {
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

        try TranscriptionCLIEvent.status(message: "Loading WhisperKit model '\(modelSize)'...").emit()
        try TranscriptionCLIEvent.progress(0.05).emit()

        let whisperKit = try await WhisperKit(model: modelSize)

        try TranscriptionCLIEvent.status(message: "Transcribing \(audioURL.lastPathComponent)...").emit()
        try TranscriptionCLIEvent.progress(0.15).emit()

        let options = DecodingOptions(
            task: .transcribe,
            language: language ?? "en",
            temperature: 0.0,
            wordTimestamps: false,
            suppressBlank: true,
            chunkingStrategy: .vad
        )

        try TranscriptionCLIEvent.status(message: "Running local speech recognition...").emit()
        let results: [TranscriptionResult] = try await whisperKit.transcribe(
            audioPath: audioPath,
            decodeOptions: options
        )

        var segments: [TranscriptionSegment] = []
        let totalSegmentCount = max(1, results.reduce(0) { $0 + $1.segments.count })
        var emittedSegmentCount = 0

        for result in results {
            for segment in result.segments {
                let text = segment.text
                    .replacing(/<\|[^|]*\|>/, with: "")
                    .trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }

                let transcriptionSegment = TranscriptionSegment(
                    text: text,
                    startTime: (TimeInterval(segment.start) * 1000).rounded() / 1000,
                    endTime: (TimeInterval(segment.end) * 1000).rounded() / 1000
                )
                segments.append(transcriptionSegment)
                emittedSegmentCount += 1

                try TranscriptionCLIEvent.segment(transcriptionSegment).emit()
                let fractional = Double(emittedSegmentCount) / Double(totalSegmentCount)
                try TranscriptionCLIEvent.progress(0.15 + (0.8 * fractional)).emit()
            }
        }

        try TranscriptionCLIEvent.status(message: "Writing transcript JSON...").emit()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(segments)
        try data.write(to: outputURL)

        let frequencies = Self.computeWordFrequencies(from: segments)
        let freqPath = outputURL
            .deletingPathExtension()
            .appendingPathExtension("word_frequencies.json")
        let freqData = try encoder.encode(frequencies)
        try freqData.write(to: freqPath)

        if !frequencies.isEmpty {
            try TranscriptionCLIEvent.wordFrequencies(words: frequencies).emit()
        }

        try TranscriptionCLIEvent.progress(1.0).emit()
        try TranscriptionCLIEvent.completed(
            outputPath: outputURL.path,
            segmentCount: segments.count,
            wordFrequencyPath: freqPath.path
        ).emit()
    }

    private static func computeWordFrequencies(
        from segments: [TranscriptionSegment],
        maxWords: Int = 50
    ) -> [CLIWordFrequency] {
        var counts: [String: Int] = [:]
        let combined = segments.map(\.text).joined(separator: " ")

        for raw in combined.lowercased().split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }) {
            let word = raw.trimmingCharacters(in: .punctuationCharacters)
            guard !word.isEmpty,
                  word.count >= 2,
                  !stopWords.contains(word),
                  word.rangeOfCharacter(from: .letters) != nil else { continue }
            counts[word, default: 0] += 1
        }

        return counts
            .map { CLIWordFrequency(word: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
            .prefix(maxWords)
            .map { $0 }
    }

    private static let stopWords: Set<String> = [
        "a", "about", "above", "after", "again", "against", "all", "am", "an", "and",
        "any", "are", "aren", "as", "at", "be", "because", "been", "before", "being",
        "below", "between", "both", "but", "by", "can", "could", "couldn", "did",
        "didn", "do", "does", "doesn", "doing", "don", "down", "during", "each",
        "few", "for", "from", "further", "had", "hadn", "has", "hasn", "have",
        "haven", "having", "he", "her", "here", "hers", "herself", "him",
        "himself", "his", "how", "i", "if", "in", "into", "is", "isn", "it",
        "its", "itself", "just", "ll", "m", "ma", "me", "might", "mightn",
        "more", "most", "mustn", "my", "myself", "needn", "no", "nor", "not",
        "now", "o", "of", "off", "on", "once", "only", "or", "other", "our",
        "ours", "ourselves", "out", "over", "own", "re", "s", "same", "shan",
        "she", "should", "shouldn", "so", "some", "such", "t", "than", "that",
        "the", "their", "theirs", "them", "themselves", "then", "there", "these",
        "they", "this", "those", "through", "to", "too", "under", "until", "up",
        "ve", "very", "was", "wasn", "we", "were", "weren", "what", "when",
        "where", "which", "while", "who", "whom", "why", "will", "with", "won",
        "would", "wouldn", "y", "you", "your", "yours", "yourself", "yourselves"
    ]
}
