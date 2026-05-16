import Foundation
import Combine
import CryptoKit

struct GlobalTranscriptIndex: Codable {
    let fileHash: String
    let fileName: String
    let segments: [TranscriptionSegment]
}

/// A word and its occurrence count, used for word cloud rendering.
struct MacWordFrequency: Codable, Hashable, Identifiable {
    var id: String { word }
    let word: String
    let count: Int
}

@MainActor
class TranscriptStore: ObservableObject {
    @Published var transcriptions: [String: [TranscriptionSegment]] = [:]
    @Published var fileMapping: [String: String] = [:] // Hash -> Title
    /// Per-hash word frequencies for the full transcript, computed on load.
    @Published var wordClouds: [String: [MacWordFrequency]] = [:]

    private let transcriptDir: URL
    private var transcriptUpdateObserver: NSObjectProtocol?

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        transcriptDir = appSupport.appendingPathComponent("Transcripts", isDirectory: true)
        loadIndex()

        transcriptUpdateObserver = NotificationCenter.default.addObserver(forName: NSNotification.Name("TranscriptDidUpdate"), object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reload() }
        }
    }

    deinit {
        if let observer = transcriptUpdateObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func loadIndex() {
        guard let files = try? FileManager.default.contentsOfDirectory(at: transcriptDir, includingPropertiesForKeys: nil) else {
#if DEBUG
            print("TranscriptStore: Could not list directory \(transcriptDir)")
#endif
            return
        }

#if DEBUG
        print("TranscriptStore: Loading from \(transcriptDir.path), found \(files.count) files")
#endif

        var newTranscriptions: [String: [TranscriptionSegment]] = [:]
        var newWordClouds: [String: [MacWordFrequency]] = [:]
        for file in files where file.pathExtension == "json" {
            let hash = file.deletingPathExtension().deletingPathExtension().lastPathComponent
            if let data = try? Data(contentsOf: file),
               let segments = try? JSONDecoder().decode([TranscriptionSegment].self, from: data) {
#if DEBUG
                print("TranscriptStore: Loaded \(segments.count) segments for hash \(hash)")
#endif
                newTranscriptions[hash] = segments
                newWordClouds[hash] = Self.computeWordFrequencies(from: segments)
                fileMapping[hash] = "Audiobook"
            } else {
#if DEBUG
                print("TranscriptStore: Failed to decode \(file.lastPathComponent)")
#endif
            }
        }
        self.transcriptions = newTranscriptions
        self.wordClouds = newWordClouds
    }

    func reload() {
        loadIndex()
    }

    func hasTranscript(forHash hash: String) -> Bool {
        transcriptions[hash] != nil
    }

    func segments(forHash hash: String) -> [TranscriptionSegment]? {
        transcriptions[hash]
    }

    func search(query: String) -> [(String, TranscriptionSegment)] {
        var results: [(String, TranscriptionSegment)] = []
        for (hash, segments) in transcriptions {
            let matches = segments.filter { $0.text.localizedCaseInsensitiveContains(query) }
            for match in matches {
                results.append((hash, match))
            }
        }
        return results
    }

    // MARK: - Word frequencies

    /// Computes word frequencies from transcription segments with stop-word filtering.
    static func computeWordFrequencies(from segments: [TranscriptionSegment]) -> [MacWordFrequency] {
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
            .map { MacWordFrequency(word: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }

    // MARK: - Stop words

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

