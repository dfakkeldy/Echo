import Foundation

public struct SlidingWindowAligner: TextAlignmentService {
    let sentenceConfidenceThreshold: Double
    let windowSize: Int
    let wordFallbackThreshold: Double
    let minimumGlobalConfidence: Double

    public init(
        sentenceConfidenceThreshold: Double = 0.80,
        windowSize: Int = 10,
        wordFallbackThreshold: Double = 0.60,
        minimumGlobalConfidence: Double = 0.30
    ) {
        self.sentenceConfidenceThreshold = sentenceConfidenceThreshold
        self.windowSize = windowSize
        self.wordFallbackThreshold = wordFallbackThreshold
        self.minimumGlobalConfidence = minimumGlobalConfidence
    }

    private let nlp = NLPProcessor()

    public func align(
        epubText: String,
        transcript: [EnhancedTranscriptionSegment]
    ) async throws -> [AlignmentResult] {
        guard !epubText.isEmpty else {
            throw AlignmentError.alignmentFailed(confidence: 0)
        }
        guard !transcript.isEmpty else {
            throw AlignmentError.transcriptEmpty(path: "provided array")
        }

        let epubSentences = nlp.sentences(from: epubText)
        guard !epubSentences.isEmpty else {
            throw AlignmentError.alignmentFailed(confidence: 0)
        }

        let sentenceRanges = computeSentenceRanges(sentences: epubSentences, in: epubText)

        var results: [AlignmentResult] = []
        var epubPosition = 0

        for segment in transcript {
            let tsSentence = segment.text
            var bestMatch: (index: Int, confidence: Double)?

            let searchEnd = Swift.min(epubPosition + windowSize, epubSentences.count)
            guard searchEnd > epubPosition else { break }

            // Pass 1: sentence-level sliding window
            for epIndex in epubPosition..<searchEnd {
                let similarity = tsSentence.normalizedLevenshteinSimilarity(to: epubSentences[epIndex])
                if similarity > (bestMatch?.confidence ?? 0) {
                    bestMatch = (epIndex, similarity)
                }
            }

            // Pass 2: word-level fallback
            if let match = bestMatch, match.confidence < wordFallbackThreshold {
                for epIndex in epubPosition..<searchEnd {
                    let epSentence = epubSentences[epIndex]
                    let tsWords = nlp.words(from: tsSentence)
                        .filter { $0.rangeOfCharacter(from: .letters) != nil }
                    let epWords = nlp.words(from: epSentence)
                        .filter { $0.rangeOfCharacter(from: .letters) != nil }
                    let wordSim = tsWords.joined(separator: " ")
                        .normalizedLevenshteinSimilarity(to: epWords.joined(separator: " "))
                    if wordSim > (bestMatch?.confidence ?? 0) {
                        bestMatch = (epIndex, wordSim)
                    }
                }
            }

            if let match = bestMatch, match.confidence >= 0.40 {
                let range = sentenceRanges[match.index]
                results.append(AlignmentResult(
                    epubCharRange: range,
                    transcriptTimeRange: segment.startTime...segment.endTime,
                    confidence: match.confidence,
                    containedMarkers: []
                ))
                epubPosition = match.index + 1
            }
        }

        guard !results.isEmpty else {
            throw AlignmentError.alignmentFailed(confidence: 0)
        }

        let avgConfidence = results.map(\.confidence).reduce(0, +) / Double(results.count)
        if avgConfidence < minimumGlobalConfidence {
            throw AlignmentError.alignmentFailed(confidence: avgConfidence)
        }

        return results
    }

    private func computeSentenceRanges(sentences: [String], in fullText: String) -> [ClosedRange<Int>] {
        var ranges: [ClosedRange<Int>] = []
        var searchStart = fullText.startIndex

        for sentence in sentences {
            if let range = fullText[searchStart...].range(of: sentence) {
                let lower = fullText.distance(from: fullText.startIndex, to: range.lowerBound)
                let upper = fullText.distance(from: fullText.startIndex, to: range.upperBound) - 1
                ranges.append(lower...upper)
                searchStart = range.upperBound
            } else {
                let lastEnd = ranges.last?.upperBound ?? -1
                ranges.append((lastEnd + 1)...(lastEnd + sentence.count))
            }
        }

        return ranges
    }
}
