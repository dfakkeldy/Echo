import Foundation

struct AutoAlignmentTextMatcher {
    struct Match {
        let block: EPubBlockRecord
        let confidence: Double
        /// Token index inside the matched block's tokenized text where the
        /// best-aligning window of the transcript starts. Lets callers
        /// back-project from a mid-block capture to the block's first-word
        /// audio time.
        let bestWindowStart: Int
        /// Token count of the transcript after lowercasing + letters-only
        /// filtering. Combined with capture duration, callers can estimate
        /// seconds-per-token to convert `bestWindowStart` into an audio
        /// offset.
        let transcriptTokenCount: Int
    }

    static func findBestMatch(
        transcribedText: String,
        candidates: [EPubBlockRecord],
        matchThreshold: Double,
        expectedIndex: Int? = nil
    ) -> Match? {
        let transcriptTokens = tokens(in: transcribedText)
        guard transcriptTokens.isEmpty == false else { return nil }

        var bestMatches: [(index: Int, match: Match)] = []
        for (i, candidate) in candidates.enumerated() {
            guard let text = candidate.text, text.isEmpty == false else { continue }

            let scored = scoreWindow(
                transcriptTokens: transcriptTokens,
                candidateTokens: tokens(in: text)
            )
            
            var finalScore = scored.score
            // Apply Locality Bias
            if let expectedIndex {
                let distance = abs(i - expectedIndex)
                // Add up to 0.15 to the score if it's exactly at the expected index,
                // degrading linearly over a distance of 15 blocks.
                let bias = max(0, 0.15 * (1.0 - Double(distance) / 15.0))
                finalScore = min(1.0, finalScore + bias)
            }

            bestMatches.append((
                index: i,
                match: Match(
                    block: candidate,
                    confidence: finalScore,
                    bestWindowStart: scored.windowStart,
                    transcriptTokenCount: transcriptTokens.count
                )
            ))
        }

        bestMatches.sort {
            let diff = $0.match.confidence - $1.match.confidence
            if abs(diff) < 0.05 {
                // If scores are very close, prefer the one closer to expectedIndex
                if let expectedIndex {
                    let d0 = abs($0.index - expectedIndex)
                    let d1 = abs($1.index - expectedIndex)
                    if d0 != d1 { return d0 < d1 }
                }
                return $0.index < $1.index
            }
            return diff > 0
        }

        guard let best = bestMatches.first?.match, best.confidence >= matchThreshold else { return nil }

        if bestMatches.count > 1 {
            let secondBest = bestMatches[1]
            if best.confidence < secondBest.match.confidence + 0.05 {
                // If the second best match is far away, we are not confident.
                if abs(secondBest.index - bestMatches[0].index) > 5 {
                    return nil
                }
            }
        }

        return best
    }

    /// Back-projects from a capture's window-start time to the matched
    /// block's first-word audio time.
    ///
    /// When the matcher's best window begins at block token `N`, the
    /// captured audio corresponds to roughly `N` tokens *into* the block —
    /// so the block's first word was spoken `N × secondsPerToken` earlier
    /// than the first transcribed word in the clip.
    ///
    /// Requires at least 3 transcript tokens to estimate a speech rate;
    /// otherwise returns `windowStart + firstWordOffset` (the prior,
    /// un-projected behavior) as a safe fallback.
    static func projectedBlockStart(
        windowStart: TimeInterval,
        firstWordOffset: TimeInterval,
        captureDuration: TimeInterval,
        transcriptTokenCount: Int,
        matchedBlockWindowStart: Int
    ) -> TimeInterval {
        let captureStart = windowStart + firstWordOffset
        guard matchedBlockWindowStart > 0,
              transcriptTokenCount >= 3,
              captureDuration > 0 else {
            return captureStart
        }
        let secondsPerToken = captureDuration / Double(transcriptTokenCount)
        return captureStart - Double(matchedBlockWindowStart) * secondsPerToken
    }

    // MARK: - Cached helpers

    /// Cached CharacterSet to avoid repeated allocation + inversion in the tight tokenization loop.
    private static let nonLetters = CharacterSet.letters.inverted

    /// Slides a transcript-sized window through the candidate's tokens and
    /// returns the best score along with the window's starting token index.
    private static func scoreWindow(
        transcriptTokens: [String],
        candidateTokens: [String]
    ) -> (score: Double, windowStart: Int) {
        guard candidateTokens.isEmpty == false else { return (0, 0) }

        // Precompute transcript-derived values once per candidate block
        // rather than on every sliding-window invocation inside score().
        let transcriptString = transcriptTokens.joined(separator: " ")
        let transcriptSet = Set(transcriptTokens)

        let windowSize = transcriptTokens.count
        let stride = max(1, windowSize / 3)

        // Seed with the full-block comparison (windowStart = 0); the windowed
        // search below will only replace this if a strictly better window is
        // found.
        var bestScore = score(
            transcriptString: transcriptString,
            transcriptSet: transcriptSet,
            candidateTokens: candidateTokens
        )
        var bestStart = 0
        var start = 0
        while start < candidateTokens.count {
            let end = min(candidateTokens.count, start + windowSize)
            let window = Array(candidateTokens[start..<end])
            let s = score(
                transcriptString: transcriptString,
                transcriptSet: transcriptSet,
                candidateTokens: window
            )
            if s > bestScore {
                bestScore = s
                bestStart = start
            }
            if end == candidateTokens.count { break }
            start += stride
        }
        return (bestScore, bestStart)
    }

    /// Computes a composite similarity score from string-level Levenshtein
    /// and word-level Jaccard overlap.  The precomputed `transcriptString`
    /// and `transcriptSet` are reused across every window for a single
    /// candidate block, avoiding O(N) redundant allocations.
    private static func score(
        transcriptString: String,
        transcriptSet: Set<String>,
        candidateTokens: [String]
    ) -> Double {
        let candidate = candidateTokens.joined(separator: " ")
        let stringConfidence = transcriptString.normalizedLevenshteinSimilarity(to: candidate)

        // Short-circuit: if string confidence is already near-perfect,
        // skip the expensive Set construction and Jaccard computation.
        if stringConfidence >= 0.95 {
            return stringConfidence
        }

        let candidateSet = Set(candidateTokens)
        let intersection = transcriptSet.intersection(candidateSet).count
        let union = transcriptSet.union(candidateSet).count
        let wordConfidence = union > 0 ? Double(intersection) / Double(union) : 0

        return max(stringConfidence, wordConfidence)
    }

    private static func tokens(in text: String) -> [String] {
        text.lowercased()
            .components(separatedBy: nonLetters)
            .filter { $0.count >= 2 }
    }
}
