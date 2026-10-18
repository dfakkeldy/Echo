// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import os.log

#if DEBUG
    import Synchronization
#endif

struct GlobalTranscriptIndex: Codable {
    let fileHash: String
    let fileName: String
    let segments: [TranscriptionSegment]
}

@MainActor
@Observable
class TranscriptStore {
    var transcriptions: [String: [TranscriptionSegment]] = [:]
    var fileMapping: [String: String] = [:]  // Hash -> Title
    /// Per-hash word frequencies for the full transcript, computed on load.
    var wordClouds: [String: [WordFrequency]] = [:]

    private let logger = Logger(category: "TranscriptStore")
    private let transcriptDir: URL
    private var loadGeneration = 0

    init() {
        let appSupport = FileLocations.applicationSupportDirectory
        transcriptDir = appSupport.appendingPathComponent("Transcripts", isDirectory: true)
        loadIndex()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleTranscriptUpdate),
            name: .transcriptDidUpdate,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func handleTranscriptUpdate() {
        reload()
    }

    #if DEBUG
        /// Test/harness-only observation seam: records whether the most recent
        /// `readIndex` call executed its body on the main thread. Mutex-protected
        /// (not `nonisolated(unsafe)`) because `readIndex` isn't provably
        /// single-caller: production `loadIndex()` and any direct test call both
        /// reach it. Exists so the off-main guarantee is verified empirically
        /// instead of trusted from the `@concurrent` annotation alone. Not
        /// compiled into release builds.
        nonisolated static let debugReadIndexRanOnMainThread = Mutex<Bool?>(nil)
        /// `Thread.isMainThread` is `NS_SWIFT_UNAVAILABLE_FROM_ASYNC` — reading it
        /// directly inside an `async` function body doesn't compile. This
        /// synchronous wrapper is the sanctioned way to read it from async code.
        nonisolated private static func debugIsMainThread() -> Bool { Thread.isMainThread }
    #endif

    /// Kicks off an off-main scan+decode of the transcript directory (via
    /// `readIndex`, which is `@concurrent` — see its doc comment for why that
    /// attribute, not just `nonisolated async`, is required) and applies the
    /// result on the main actor. Non-blocking: launch no longer waits while
    /// every transcript JSON is decoded and word-frequency-counted (audit fix 4).
    func loadIndex() {
        loadGeneration += 1
        let generation = loadGeneration
        let dir = transcriptDir
        Task(priority: .utility) { [weak self] in
            let loaded = await Self.readIndex(from: dir)
            guard let self, self.loadGeneration == generation else { return }
            guard let loaded else { return }
            self.transcriptions = loaded.transcriptions
            self.wordClouds = loaded.wordClouds
            for hash in loaded.transcriptions.keys { self.fileMapping[hash] = "Audiobook" }
        }
    }

    /// Pure directory scan + JSON decode + word-frequency compute, off the main
    /// actor. `@concurrent` (not plain `nonisolated async`) is what actually
    /// moves this onto the cooperative pool: this project builds with
    /// `SWIFT_APPROACHABLE_CONCURRENCY = YES`, which enables
    /// `NonisolatedNonsendingByDefault` — under that mode a plain `nonisolated
    /// async` function called from this `@MainActor` class's `Task { ... }`
    /// (an unstructured `Task` inherits the enclosing actor) runs ON the main
    /// thread, not off it. Do not drop `@concurrent` under the assumption that
    /// `nonisolated async` alone suspends off-main; it does not, here.
    @concurrent
    nonisolated static func readIndex(from transcriptDir: URL) async -> (
        transcriptions: [String: [TranscriptionSegment]],
        wordClouds: [String: [WordFrequency]]
    )? {
        #if DEBUG
            let isMainThread = Self.debugIsMainThread()
            Self.debugReadIndexRanOnMainThread.withLock { $0 = isMainThread }
        #endif
        guard
            let files = try? FileManager.default.contentsOfDirectory(
                at: transcriptDir, includingPropertiesForKeys: nil)
        else { return nil }

        var newTranscriptions: [String: [TranscriptionSegment]] = [:]
        var newWordClouds: [String: [WordFrequency]] = [:]
        for file in files where file.pathExtension == "json" {
            let stem = file.deletingPathExtension().lastPathComponent
            guard !stem.hasSuffix(".word_frequencies") else { continue }
            let hash = file.deletingPathExtension().deletingPathExtension().lastPathComponent
            guard let data = try? Data(contentsOf: file),
                let segments = try? JSONDecoder().decode([TranscriptionSegment].self, from: data)
            else { continue }
            newTranscriptions[hash] = segments
            let freqSidecar = transcriptDir.appendingPathComponent(
                "\(hash).transcript.word_frequencies.json")
            if let freqData = try? Data(contentsOf: freqSidecar),
                let freq = try? JSONDecoder().decode([WordFrequency].self, from: freqData)
            {
                newWordClouds[hash] = freq
            } else {
                newWordClouds[hash] = Self.computeWordFrequencies(from: segments)
            }
        }
        return (newTranscriptions, newWordClouds)
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
    nonisolated static func computeWordFrequencies(from segments: [TranscriptionSegment])
        -> [WordFrequency]
    {
        var counts: [String: Int] = [:]
        let combined = segments.map(\.text).joined(separator: " ")

        for raw in combined.lowercased().split(whereSeparator: {
            $0.isWhitespace || $0.isPunctuation
        }) {
            let word = raw.trimmingCharacters(in: .punctuationCharacters)
            guard !word.isEmpty,
                word.count >= 2,
                !stopWords.contains(word),
                word.rangeOfCharacter(from: .letters) != nil
            else { continue }
            counts[word, default: 0] += 1
        }

        return
            counts
            .map { WordFrequency(word: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }

    // MARK: - Stop words

    private nonisolated static let stopWords: Set<String> = [
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
        "would", "wouldn", "y", "you", "your", "yours", "yourself", "yourselves",
    ]
}
