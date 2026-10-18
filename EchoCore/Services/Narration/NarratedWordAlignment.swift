// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Maps the words Echo *speaks* back onto the words the reader *shows*.
///
/// `TextNormalizer` rewrites a block before synthesis so Kokoro can pronounce
/// it: "1,200" is spoken as "one thousand two hundred". That changes the word
/// sequence, and the two sides of read-along disagree about what a word is —
/// synthesis timings are indexed by the *narrated* words, while the reader
/// tokenizes the *source* text (`WordTokenizer`, `ParagraphCardCell`) and
/// highlights word N of what is on screen. Unlike an em dash, an expansion
/// cannot be fixed by preserving a token: "1,200" genuinely cannot be spoken as
/// one word without wrecking prosody. So the narrated words have to be folded
/// back onto the authored word that produced them.
///
/// This is the same contract `KokoroWordTimer.wordGroupCounts` applies one layer
/// down (several phoneme groups per narrated word); here it is several narrated
/// words per source word.
///
/// Pure and deterministic — unit-tested without the model or the database.
/// Every entry point returns `nil` rather than guessing, so an unproven mapping
/// costs a block its synthesis timings (it keeps interpolation) instead of
/// shifting every later word onto the wrong audio.
nonisolated enum NarratedWordAlignment {
    /// How many narrated words each source word became, in reading order.
    ///
    /// Returns `nil` when the mapping cannot be proven: a source word that no
    /// narrated word covers, narrated words owned by no source word, or a
    /// changed region where several source words became several narrated words
    /// and there is no evidence for where to split.
    static func expansionCounts(source: String, narrated: String) -> [Int]? {
        let sourceWords = WordTokenizer.words(in: source).map(String.init)
        let narratedWords = WordTokenizer.words(in: narrated).map(String.init)
        guard !sourceWords.isEmpty, !narratedWords.isEmpty else { return nil }
        // The overwhelmingly common case: nothing expanded, so nothing to align.
        if sourceWords == narratedWords {
            return [Int](repeating: 1, count: sourceWords.count)
        }

        // Expansions are local, so trimming the untouched head and tail leaves a
        // small changed middle. This keeps the alignment table proportional to
        // what actually changed rather than to the length of the paragraph.
        // The bounds are hoisted and the loops written out rather than folded
        // into multi-clause `while` conditions, which are cheap to read but
        // expensive for the type checker.
        let sourceCount = sourceWords.count
        let narratedCount = narratedWords.count
        let shorterCount = min(sourceCount, narratedCount)

        var prefix = 0
        while prefix < shorterCount {
            if sourceWords[prefix] != narratedWords[prefix] { break }
            prefix += 1
        }
        var suffix = 0
        let maxSuffix = shorterCount - prefix
        while suffix < maxSuffix {
            if sourceWords[sourceCount - 1 - suffix] != narratedWords[narratedCount - 1 - suffix] {
                break
            }
            suffix += 1
        }

        let sourceMiddle = Array(sourceWords[prefix..<(sourceCount - suffix)])
        let narratedMiddle = Array(narratedWords[prefix..<(narratedCount - suffix)])
        guard let middleCounts = middleExpansionCounts(sourceMiddle, narratedMiddle) else {
            return nil
        }

        let counts =
            [Int](repeating: 1, count: prefix) + middleCounts + [Int](repeating: 1, count: suffix)
        // Both the shape and the total are checked, so a mapping that does not
        // account for exactly these words falls back rather than drifting.
        guard counts.count == sourceWords.count,
            counts.allSatisfy({ $0 > 0 }),
            counts.reduce(0, +) == narratedWords.count
        else { return nil }
        return counts
    }

    /// Aligns the changed middle by anchoring on words both sides still share
    /// (a longest-common-subsequence walk), then attributing each run of
    /// narrated words between anchors to the single source word it replaced.
    private static func middleExpansionCounts(
        _ sourceWords: [String], _ narratedWords: [String]
    ) -> [Int]? {
        guard !sourceWords.isEmpty, !narratedWords.isEmpty else { return nil }

        var lengths = [[Int]](
            repeating: [Int](repeating: 0, count: narratedWords.count + 1),
            count: sourceWords.count + 1)
        for i in stride(from: sourceWords.count - 1, through: 0, by: -1) {
            for j in stride(from: narratedWords.count - 1, through: 0, by: -1) {
                lengths[i][j] =
                    sourceWords[i] == narratedWords[j]
                    ? lengths[i + 1][j + 1] + 1
                    : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }

        var counts = [Int](repeating: 0, count: sourceWords.count)
        var sourceCursor = 0
        var narratedCursor = 0
        /// Attributes `narrated[narratedCursor..<narratedEnd]` to
        /// `source[sourceCursor..<sourceEnd]`. Anything but "one source word
        /// became one or more narrated words" is unproven.
        func attributeRegion(sourceEnd: Int, narratedEnd: Int) -> Bool {
            let sourceRun = sourceEnd - sourceCursor
            let narratedRun = narratedEnd - narratedCursor
            if sourceRun == 0 { return narratedRun == 0 }
            guard sourceRun == 1, narratedRun >= 1 else { return false }
            counts[sourceCursor] = narratedRun
            return true
        }

        var i = 0
        var j = 0
        while i < sourceWords.count, j < narratedWords.count {
            if sourceWords[i] == narratedWords[j] {
                guard attributeRegion(sourceEnd: i, narratedEnd: j) else { return nil }
                counts[i] = 1
                sourceCursor = i + 1
                narratedCursor = j + 1
                i += 1
                j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        guard
            attributeRegion(sourceEnd: sourceWords.count, narratedEnd: narratedWords.count)
        else { return nil }
        return counts
    }

    /// Folds narrated word timings into one span per source word: the span runs
    /// from the first narrated word's start to the last one's end, so the pause
    /// inside "one thousand — two hundred" belongs to the authored word "1,200"
    /// rather than reading as an inter-word gap.
    ///
    /// `timings` must be in reading order. Returns `nil` unless `counts`
    /// accounts for exactly these timings.
    static func collapse(_ timings: [ChunkWordTiming], counts: [Int]) -> [ChunkWordTiming]? {
        guard !timings.isEmpty, !counts.isEmpty,
            counts.allSatisfy({ $0 > 0 }),
            counts.reduce(0, +) == timings.count
        else { return nil }

        var collapsed: [ChunkWordTiming] = []
        collapsed.reserveCapacity(counts.count)
        var index = 0
        for (wordIndex, count) in counts.enumerated() {
            collapsed.append(
                ChunkWordTiming(
                    wordIndex: wordIndex,
                    start: timings[index].start,
                    end: timings[index + count - 1].end))
            index += count
        }
        return collapsed
    }
}
