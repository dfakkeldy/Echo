import Foundation

struct TokenDTW {
    struct EPubToken {
        let text: String
        let blockID: String
    }

    struct AudioToken {
        let text: String
        let time: TimeInterval
    }

    /// A proposed anchor for one EPUB block, with enough evidence attached
    /// for `AnchorSelector` to keep or reject it.
    ///
    /// `time` estimates the block's *first word* utterance: the audio time of
    /// the block's first strong token match, back-projected by
    /// `firstMatchTokenIndex × local speech rate` when the match starts
    /// mid-block (e.g. the opening words were mistranscribed).
    struct AnchorCandidate: Equatable {
        let blockID: String
        let time: TimeInterval
        /// Length of the contiguous strong-match run (exact or prefix token
        /// matches, uninterrupted by gaps or substitutions) containing this
        /// block's first strong match. Runs span block boundaries, so a
        /// two-token heading inherits confidence from the words around it.
        let exactRunLength: Int
        /// Index within the block's tokens of the first strong match.
        let firstMatchTokenIndex: Int
    }

    /// Tokenizes text for alignment: lowercased, split on non-alphanumerics,
    /// digit runs expanded to spoken number words so "Chapter 2" can match a
    /// narrator's "chapter two". Pure-letter tokens shorter than 2 characters
    /// are dropped ("a", "I") — they carry no alignment signal.
    static func normalize(_ text: String) -> [String] {
        let separators = CharacterSet.alphanumerics.inverted
        var tokens: [String] = []
        for component in text.lowercased().components(separatedBy: separators) {
            guard !component.isEmpty else { continue }
            if component.allSatisfy(\.isNumber) {
                tokens.append(contentsOf: numberWords(component))
            } else if component.count >= 2 {
                tokens.append(component)
            }
        }
        return tokens
    }

    private static let onesWords = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
    ]
    private static let teensWords = [
        "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen",
        "eighteen", "nineteen",
    ]
    private static let tensWords = [
        "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety",
    ]

    /// Expands a digit run into spoken-word tokens. One- and two-digit
    /// numbers read naturally ("21" → twenty, one); anything longer reads
    /// per digit — the same expansion is applied to both the EPUB and the
    /// transcript side, so the representation cancels out for DTW.
    private static func numberWords(_ digits: String) -> [String] {
        if digits.count <= 2, let value = Int(digits) {
            if value < 10 { return [onesWords[value]] }
            if value < 20 { return [teensWords[value - 10]] }
            let tens = tensWords[value / 10 - 2]
            let remainder = value % 10
            return remainder == 0 ? [tens] : [tens, onesWords[remainder]]
        }
        return digits.compactMap { character in
            character.wholeNumberValue.flatMap { $0 < 10 ? onesWords[$0] : nil }
        }
    }

    // MARK: - Candidate-Producing Alignment

    private enum Cost {
        static let exact: Int32 = 0
        static let prefix: Int32 = 1
        /// Substitution must cost more than one gap but less than two:
        /// skipping a never-narrated span beats absorbing audio that belongs
        /// to later text, while a single mistranscribed word still prefers
        /// substitution over breaking the path with two gaps.
        static let substitution: Int32 = 3
        static let gap: Int32 = 2
    }

    /// Aligns EPUB tokens against transcribed audio tokens and returns one
    /// `AnchorCandidate` per block that achieved at least one strong match.
    ///
    /// Unlike the legacy `align(epub:audio:)`, blocks whose text never
    /// appears in the audio produce *no* candidate — the cost model prefers
    /// skipping unmatched spans over inventing substitutions, and only exact
    /// or prefix token matches count as anchor evidence.
    static func alignCandidates(
        epub: [EPubToken],
        audio: [AudioToken]
    ) -> [AnchorCandidate] {
        let n = epub.count
        let m = audio.count
        guard n > 0, m > 0 else { return [] }

        // ── DP forward pass (two rolling cost rows, full direction matrix) ──
        var cost0 = [Int32](repeating: .max / 2, count: m + 1)
        var cost1 = [Int32](repeating: .max / 2, count: m + 1)
        var dir = [Int8](repeating: 0, count: (n + 1) * (m + 1))

        cost0[0] = 0
        for j in 1...m { cost0[j] = Int32(j) * Cost.gap }

        for i in 1...n {
            cost1[0] = Int32(i) * Cost.gap
            let eToken = epub[i - 1].text
            for j in 1...m {
                let aToken = audio[j - 1].text
                let matchCost: Int32
                if eToken == aToken {
                    matchCost = Cost.exact
                } else if eToken.hasPrefix(aToken) || aToken.hasPrefix(eToken) {
                    matchCost = Cost.prefix
                } else {
                    matchCost = Cost.substitution
                }

                let sub = cost0[j - 1] + matchCost
                let ins = cost1[j - 1] + Cost.gap
                let del = cost0[j] + Cost.gap

                let idx = i * (m + 1) + j
                if sub <= ins && sub <= del {
                    cost1[j] = sub
                    dir[idx] = 0
                } else if ins <= del {
                    cost1[j] = ins
                    dir[idx] = 1
                } else {
                    cost1[j] = del
                    dir[idx] = 2
                }
            }
            swap(&cost0, &cost1)
        }

        // ── Backtrack into forward path order ──
        struct PathMatch {
            let epubIndex: Int
            let audioIndex: Int
            let strong: Bool
        }
        var matches: [PathMatch] = []
        var i = n
        var j = m
        while i > 0 && j > 0 {
            let idx = i * (m + 1) + j
            switch dir[idx] {
            case 0:
                let eToken = epub[i - 1].text
                let aToken = audio[j - 1].text
                let strong =
                    eToken == aToken
                    || eToken.hasPrefix(aToken) || aToken.hasPrefix(eToken)
                matches.append(PathMatch(epubIndex: i - 1, audioIndex: j - 1, strong: strong))
                i -= 1
                j -= 1
            case 1:
                j -= 1
            default:
                i -= 1
            }
        }
        matches.reverse()

        // ── Strong-run bookkeeping ──
        // A run is a maximal sequence of path-adjacent strong matches:
        // consecutive in the path AND diagonal in both indices, so any gap
        // or substitution step breaks it.
        struct RunStats {
            var count: Int
            var firstTime: TimeInterval
            var lastTime: TimeInterval
        }
        var runIDs = [Int](repeating: -1, count: matches.count)
        var runs: [RunStats] = []
        for k in matches.indices where matches[k].strong {
            let match = matches[k]
            let time = audio[match.audioIndex].time
            if k > 0, runIDs[k - 1] >= 0,
                matches[k - 1].epubIndex == match.epubIndex - 1,
                matches[k - 1].audioIndex == match.audioIndex - 1
            {
                runIDs[k] = runIDs[k - 1]
                runs[runIDs[k]].count += 1
                runs[runIDs[k]].lastTime = time
            } else {
                runs.append(RunStats(count: 1, firstTime: time, lastTime: time))
                runIDs[k] = runs.count - 1
            }
        }

        // Token position of each EPUB token within its block, for
        // back-projecting mid-block matches to the block start.
        var tokenIndexInBlock = [Int](repeating: 0, count: n)
        var blockCursor: String?
        var withinBlock = 0
        for k in 0..<n {
            if epub[k].blockID != blockCursor {
                blockCursor = epub[k].blockID
                withinBlock = 0
            }
            tokenIndexInBlock[k] = withinBlock
            withinBlock += 1
        }

        // ── Emit one candidate per block: its first strong match ──
        var candidateByBlock: [String: AnchorCandidate] = [:]
        var blockOrder: [String] = []
        for k in matches.indices where matches[k].strong {
            let match = matches[k]
            let blockID = epub[match.epubIndex].blockID
            guard candidateByBlock[blockID] == nil else { continue }

            let stats = runs[runIDs[k]]
            let tokenIndex = tokenIndexInBlock[match.epubIndex]
            let matchTime = audio[match.audioIndex].time

            // Local speech rate from this run's own word times; clamped to
            // plausible narration bounds so a pause inside the run can't
            // catapult the projection.
            let rate: TimeInterval
            if stats.count >= 2 {
                // WhisperKit word times aren't guaranteed monotonic across
                // concatenated chunks, so guard against a negative span that
                // would otherwise produce a bogus rate (§5.11).
                let span = max(0, stats.lastTime - stats.firstTime)
                rate = min(1.0, max(0.15, span / Double(stats.count - 1)))
            } else {
                rate = 0.4
            }
            let time = max(0, matchTime - Double(tokenIndex) * rate)

            candidateByBlock[blockID] = AnchorCandidate(
                blockID: blockID,
                time: time,
                exactRunLength: stats.count,
                firstMatchTokenIndex: tokenIndex
            )
            blockOrder.append(blockID)
        }
        return blockOrder.compactMap { candidateByBlock[$0] }
    }

    /// Memory-guarded wrapper around `alignCandidates`.
    ///
    /// The DTW direction matrix is `(n+1)×(m+1)` bytes. When `epub.count ×
    /// audio.count` exceeds `maxCells`, the audio is bisected at the largest
    /// inter-token time gap in its middle third (≈ a paragraph or section
    /// pause), the EPUB tokens are split at the proportional block boundary
    /// with `slackBlocks` blocks of overlap on each side of the seam, and
    /// both halves recurse. Duplicate candidates from the overlap keep the
    /// stronger run.
    static func alignWithBisection(
        epub: [EPubToken],
        audio: [AudioToken],
        maxCells: Int = 48_000_000,
        slackBlocks: Int = 12
    ) -> [AnchorCandidate] {
        guard !epub.isEmpty, !audio.isEmpty else { return [] }
        guard epub.count * audio.count > maxCells, audio.count >= 8 else {
            return alignCandidates(epub: epub, audio: audio)
        }

        let lower = audio.count / 3
        let upper = (audio.count * 2) / 3
        var splitIndex = audio.count / 2
        var widestGap = -1.0
        for k in lower..<max(lower + 1, upper) where k + 1 < audio.count {
            let gap = audio[k + 1].time - audio[k].time
            if gap > widestGap {
                widestGap = gap
                splitIndex = k + 1
            }
        }

        let audioFirst = Array(audio[..<splitIndex])
        let audioSecond = Array(audio[splitIndex...])

        var blockStartIndices: [Int] = []
        var lastBlockID: String?
        for (index, token) in epub.enumerated() where token.blockID != lastBlockID {
            blockStartIndices.append(index)
            lastBlockID = token.blockID
        }

        let pivot = Int(Double(splitIndex) / Double(audio.count) * Double(epub.count))
        let pivotOrdinal = blockStartIndices.lastIndex { $0 <= pivot } ?? 0
        let firstCutOrdinal = pivotOrdinal + slackBlocks + 1
        let epubFirstEnd =
            firstCutOrdinal < blockStartIndices.count
            ? blockStartIndices[firstCutOrdinal] : epub.count
        let epubSecondStart = blockStartIndices[max(0, pivotOrdinal - slackBlocks)]

        let first = alignWithBisection(
            epub: Array(epub[..<epubFirstEnd]), audio: audioFirst,
            maxCells: maxCells, slackBlocks: slackBlocks
        )
        let second = alignWithBisection(
            epub: Array(epub[epubSecondStart...]), audio: audioSecond,
            maxCells: maxCells, slackBlocks: slackBlocks
        )

        var merged: [String: AnchorCandidate] = [:]
        var order: [String] = []
        for candidate in first + second {
            if let existing = merged[candidate.blockID] {
                if candidate.exactRunLength > existing.exactRunLength {
                    merged[candidate.blockID] = candidate
                }
            } else {
                merged[candidate.blockID] = candidate
                order.append(candidate.blockID)
            }
        }
        return order.compactMap { merged[$0] }
    }
}
