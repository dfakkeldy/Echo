import Foundation

/// Computes word frequencies from transcription segments with stop-word filtering
/// and optional time-range scoping (per-chapter, rolling windows).
struct WordFrequencyComputer {

    /// Maximum number of words to return (sorted by frequency descending).
    static let defaultMaxWords = 50

    // MARK: - Core computation

    /// Compute word frequencies for all segments across the entire track.
    static func compute(from segments: [TranscriptionSegment]) -> [WordFrequency] {
        compute(from: segments, range: nil)
    }

    /// Compute word frequencies for segments whose time range overlaps the given range.
    /// Pass `nil` for the range to include all segments.
    static func compute(from segments: [TranscriptionSegment],
                        range: ClosedRange<TimeInterval>?) -> [WordFrequency] {
        let filtered = range.map { r in
            segments.filter { $0.startTime <= r.upperBound && $0.endTime >= r.lowerBound }
        } ?? segments

        let combined = filtered.map(\.text).joined(separator: " ")
        return frequencies(from: combined)
    }

    // MARK: - Per-chapter

    /// Compute word frequencies for each chapter, keyed by chapter index.
    static func computePerChapter(segments: [TranscriptionSegment],
                                  chapters: [Chapter]) -> [Int: [WordFrequency]] {
        var result: [Int: [WordFrequency]] = [:]
        for chapter in chapters {
            let range = chapter.startSeconds...chapter.endSeconds
            let words = compute(from: segments, range: range)
            if !words.isEmpty {
                result[chapter.index] = words
            }
        }
        return result
    }

    // MARK: - Rolling windows

    /// Compute word frequencies for rolling time windows across the track.
    /// - Parameters:
    ///   - segments: The transcription segments.
    ///   - windowDuration: Width of each window in seconds (default 300 = 5 min).
    ///   - step: Advance between windows in seconds (default 60 = 1 min).
    /// - Returns: Array of `(windowStartTime, frequencies)` tuples.
    static func computeRollingWindows(segments: [TranscriptionSegment],
                                      windowDuration: TimeInterval = 300,
                                      step: TimeInterval = 60) -> [(TimeInterval, [WordFrequency])] {
        guard !segments.isEmpty, let lastEnd = segments.last?.endTime else { return [] }

        var results: [(TimeInterval, [WordFrequency])] = []
        var windowStart: TimeInterval = 0

        while windowStart < lastEnd {
            let windowEnd = windowStart + windowDuration
            let range = windowStart...windowEnd
            let words = compute(from: segments, range: range)
            if !words.isEmpty {
                results.append((windowStart, words))
            }
            windowStart += step
        }

        return results
    }

    // MARK: - Tokenization

    /// Tokenizes text, filters stop words, counts frequencies, and returns
    /// the top results sorted by count descending.
    private static func frequencies(from text: String) -> [WordFrequency] {
        var counts: [String: Int] = [:]

        for raw in text.lowercased().split(whereSeparator: { $0.isWhitespace || $0.isPunctuation }) {
            let word = raw.trimmingCharacters(in: .punctuationCharacters)
            guard !word.isEmpty,
                  word.count >= 2,
                  !stopWords.contains(word),
                  word.rangeOfCharacter(from: .letters) != nil else { continue }
            counts[word, default: 0] += 1
        }

        return counts
            .map { WordFrequency(word: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
    }

    // MARK: - Stop words

    /// English stop words filtered out during frequency computation.
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
