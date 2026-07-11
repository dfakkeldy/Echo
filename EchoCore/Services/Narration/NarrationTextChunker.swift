// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Splits a block of prose into sub-chunks the TTS model can synthesize in one
/// call. The hard ceiling is Kokoro's ~510-phoneme context (the `af_heart` style
/// pack has exactly 510 rows = `MAX_PHONEME_LENGTH`; past it the style row
/// saturates and the model runs beyond its trained length). English phonemizes at
/// ~1.0–1.3 phonemes per character, so the default budget stays well under 510.
///
/// Bigger chunks are better for prosody: each `synthesize` call is an independent
/// utterance whose final word gets sentence-final intonation (a falling pitch and
/// trailing pause), so every chunk seam is an audible "period." Fewer, longer
/// chunks mean fewer seams. (The old 200-char cap was a FluidAudio/CoreML-era
/// guard against an ANE BNNS vocoder trap on long dynamic shapes; that engine was
/// replaced by the ONNX Runtime CPU EP, which has no such trap and runs dynamic
/// shapes natively — so the budget could be relaxed toward the real ceiling.)
///
/// Pure and deterministic so it's unit-testable without the real model.
///
/// Contract:
/// - Every returned piece has `count <= maxChars`.
/// - Splits preferentially at sentence terminators (`. ! ?`); descends to clause
///   marks (`; , :`) only to break a single sentence that is itself over budget,
///   then to word boundaries, and only hard-splits a single word longer than
///   `maxChars`. Keeping seams off mid-sentence commas avoids the model applying
///   sentence-final intonation (an audible "period") where a comma belongs.
/// - Never loses content: concatenating the pieces reproduces the input modulo
///   collapsed runs of whitespace.
/// - Empty / whitespace-only input → `[]`.
enum NarrationTextChunker {

    /// Default budget: 350 chars ≈ 350–455 phonemes, a comfortable margin under
    /// Kokoro's ~510-phoneme ceiling while roughly halving the synth-call count
    /// (and so the number of audible chunk seams) versus the old 200-char cap.
    static func split(_ text: String, maxChars: Int = 350) -> [String] {
        guard maxChars > 0 else { return [] }

        // Normalize whitespace runs to single spaces so piece lengths are
        // predictable and joining reproduces the text modulo whitespace.
        let normalized = text.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !normalized.isEmpty else { return [] }

        var pieces: [String] = []
        // Tier 1 — sentence terminators (. ! ?). A seam here is a real stop, so the
        // model's sentence-final intonation (falling pitch + pause) is appropriate.
        for sentence in mergedUnits(normalized, maxChars: maxChars, isBoundary: isSentenceBoundary)
        {
            if sentence.count <= maxChars {
                pieces.append(sentence)
                continue
            }
            // Tier 2 — only for a single sentence over budget: clause boundaries
            // (; , :). A comma seam is less wrong than wrapping mid-clause; tier 1
            // already kept seams off commas wherever the sentences fit the budget.
            for clause in mergedUnits(sentence, maxChars: maxChars, isBoundary: isClauseBoundary) {
                if clause.count <= maxChars {
                    pieces.append(clause)
                } else {
                    pieces.append(contentsOf: wrapByWords(clause, maxChars: maxChars))
                }
            }
        }
        // Drop chunks that are purely decorative — punctuation, separators,
        // or character sequences with no speakable content. Synthesizing
        // "* * *" produces a stutter or silent audio gap, wasting ANE time
        // and producing audible artifacts in the narration stream.
        pieces = pieces.filter { chunk in
            let speakable = chunk.filter { $0.isLetter || $0.isNumber }
            return !speakable.isEmpty
        }
        return pieces
    }

    static func splitByEstimatedPhonemes(
        _ text: String,
        maxPhonemes: Int = 420,
        phonemeCount: (String) -> Int
    ) -> [String] {
        guard maxPhonemes > 0 else { return [] }
        let normalized = text.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !normalized.isEmpty else { return [] }

        let units = splitUnits(normalized, isBoundary: isSentenceBoundary)
        let pieces = mergeByPhonemeBudget(
            units,
            maxPhonemes: maxPhonemes,
            phonemeCount: phonemeCount
        ).flatMap { unit -> [String] in
            if phonemeCount(unit) <= maxPhonemes { return [unit] }
            return wrapByWords(
                unit,
                maxPhonemes: maxPhonemes,
                phonemeCount: phonemeCount)
        }
        return pieces.filter { chunk in
            let speakable = chunk.filter { $0.isLetter || $0.isNumber }
            return !speakable.isEmpty
        }
    }

    /// Splits text whose pronunciation links have already been resolved. Valid
    /// Misaki links remain byte-for-byte intact and count as one word even when
    /// their IPA contains spaces.
    static func splitResolved(
        _ text: String,
        maxPhonemes: Int = 420,
        phonemeCount: (String) -> Int
    ) -> [String] {
        guard maxPhonemes > 0 else { return [] }
        let normalized = normalizeResolvedText(text)
        guard !normalized.isEmpty else { return [] }

        let sentences = mergeByPhonemeBudget(
            splitResolvedUnits(normalized, isBoundary: isSentenceBoundary),
            maxPhonemes: maxPhonemes,
            phonemeCount: phonemeCount
        )

        let pieces = sentences.flatMap { sentence -> [String] in
            if phonemeCount(sentence) <= maxPhonemes { return [sentence] }

            return mergeByPhonemeBudget(
                splitResolvedUnits(sentence, isBoundary: isClauseBoundary),
                maxPhonemes: maxPhonemes,
                phonemeCount: phonemeCount
            ).flatMap { clause -> [String] in
                if phonemeCount(clause) <= maxPhonemes { return [clause] }
                return wrapResolvedByWords(
                    clause,
                    maxPhonemes: maxPhonemes,
                    phonemeCount: phonemeCount
                )
            }
        }

        return pieces.filter { chunk in
            chunk.contains { $0.isLetter || $0.isNumber }
        }
    }

    /// Splits `text` at the boundaries `isBoundary` accepts, then greedily merges
    /// adjacent units so each accumulated piece stays `<= maxChars`. Boundaries
    /// keep their trailing punctuation; newlines were already folded to spaces by
    /// `split`. Reused for both tiers — sentence terminators, then clause marks.
    private static func mergedUnits(
        _ text: String, maxChars: Int, isBoundary: (Character, Int, [Character]) -> Bool
    ) -> [String] {
        let units = splitUnits(text, isBoundary: isBoundary)

        // Greedily merge adjacent units that still fit under the budget, so a
        // paragraph of short sentences doesn't produce one synth call per
        // sentence (which would over-fragment the audio).
        var merged: [String] = []
        for s in units {
            if let last = merged.last, last.count + 1 + s.count <= maxChars {
                merged[merged.count - 1] = last + " " + s
            } else {
                merged.append(s)
            }
        }
        return merged
    }

    private static func splitUnits(
        _ text: String,
        isBoundary: (Character, Int, [Character]) -> Bool
    ) -> [String] {
        var units: [String] = []
        var current = ""

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { units.append(trimmed) }
            current = ""
        }

        // Don't split inside a pronunciation-override link `[word](/ipa/)`: an IPA
        // syllable separator "." is a legitimate terminator-looking character, and
        // splitting there would insert spaces inside the link and corrupt it.
        var inLink = false
        let chars = Array(text)
        for i in chars.indices {
            let ch = chars[i]
            current.append(ch)
            if ch == "[" {
                inLink = true
            } else if ch == "]" {
                // Close the protected region on `]` UNLESS this is a real
                // `[word](/ipa/)` link (next char is `(`), whose IPA dots must
                // stay protected through the closing `)`. Editorial brackets
                // like `[sic]`/`[1]` close here, so later sentences still split.
                if i + 1 >= chars.count || chars[i + 1] != "(" { inLink = false }
            } else if ch == ")" {
                inLink = false
            }
            if !inLink, isBoundary(ch, i, chars) {
                flush()
            }
        }
        flush()

        return units
    }

    private static func normalizeResolvedText(_ text: String) -> String {
        var normalized = ""
        var index = text.startIndex
        var needsSpace = false

        while index < text.endIndex {
            if let link = MisakiPronunciationMarkup.link(in: text, startingAt: index) {
                if needsSpace, !normalized.isEmpty { normalized.append(" ") }
                normalized.append(contentsOf: text[link.range])
                needsSpace = false
                index = link.range.upperBound
                continue
            }

            let character = text[index]
            if character.isWhitespace {
                needsSpace = !normalized.isEmpty
            } else {
                if needsSpace { normalized.append(" ") }
                normalized.append(character)
                needsSpace = false
            }
            index = text.index(after: index)
        }

        return normalized
    }

    private static func splitResolvedUnits(
        _ text: String,
        isBoundary: (Character, Int, [Character]) -> Bool
    ) -> [String] {
        var units: [String] = []
        var current = ""
        var textIndex = text.startIndex
        var characterIndex = 0
        let characters = Array(text)

        func flush() {
            let trimmed = current.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { units.append(trimmed) }
            current = ""
        }

        while textIndex < text.endIndex {
            if let link = MisakiPronunciationMarkup.link(in: text, startingAt: textIndex) {
                current.append(contentsOf: text[link.range])
                characterIndex += text[link.range].count
                textIndex = link.range.upperBound
                continue
            }

            let character = text[textIndex]
            current.append(character)
            if isBoundary(character, characterIndex, characters) {
                flush()
            }
            characterIndex += 1
            textIndex = text.index(after: textIndex)
        }
        flush()

        return units
    }

    private static func mergeByPhonemeBudget(
        _ units: [String],
        maxPhonemes: Int,
        phonemeCount: (String) -> Int
    ) -> [String] {
        var merged: [String] = []
        for unit in units {
            guard let last = merged.last else {
                merged.append(unit)
                continue
            }
            let candidate = last + " " + unit
            if phonemeCount(candidate) <= maxPhonemes {
                merged[merged.count - 1] = candidate
            } else {
                merged.append(unit)
            }
        }
        return merged
    }

    /// Tier 1: full-stop terminators. Seams here read as natural sentence ends.
    private static func isSentenceBoundary(_ ch: Character, at index: Int, in chars: [Character])
        -> Bool
    {
        if ch == "." {
            return !hasDigitNeighbor(at: index, in: chars)
        }
        return ch == "!" || ch == "?"
    }

    /// Tier 2: in-sentence clause marks, used only to break a single over-long
    /// sentence. `,`/`:` are ignored when they sit between digits (e.g. `3,000`,
    /// `12:30`) so numbers and times aren't split mid-token.
    private static func isClauseBoundary(_ ch: Character, at index: Int, in chars: [Character])
        -> Bool
    {
        if ch == ";" { return true }
        if ch == "," || ch == ":" {
            return !hasDigitNeighbor(at: index, in: chars)
        }
        return false
    }

    private static func hasDigitNeighbor(at index: Int, in chars: [Character]) -> Bool {
        let hasPreviousDigit = index > chars.startIndex && chars[index - 1].isNumber
        let nextIndex = index + 1
        let hasNextDigit = nextIndex < chars.endIndex && chars[nextIndex].isNumber
        return hasPreviousDigit && hasNextDigit
    }

    /// Wraps an over-long unit at word boundaries; a single word longer than
    /// `maxChars` is hard-split so no piece ever exceeds the budget.
    private static func wrapByWords(_ text: String, maxChars: Int) -> [String] {
        var pieces: [String] = []
        var current = ""

        for word in text.split(separator: " ") {
            let w = String(word)
            if w.count > maxChars {
                // Flush what we have, then hard-split the over-long word.
                if !current.isEmpty {
                    pieces.append(current)
                    current = ""
                }
                pieces.append(contentsOf: hardSplit(w, maxChars: maxChars))
                continue
            }
            if current.isEmpty {
                current = w
            } else if current.count + 1 + w.count <= maxChars {
                current += " " + w
            } else {
                pieces.append(current)
                current = w
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    private static func wrapByWords(
        _ text: String,
        maxPhonemes: Int,
        phonemeCount: (String) -> Int
    ) -> [String] {
        var pieces: [String] = []
        var current = ""

        for word in text.split(separator: " ") {
            let w = String(word)
            if current.isEmpty {
                current = w
                continue
            }

            let candidate = current + " " + w
            if phonemeCount(candidate) <= maxPhonemes {
                current = candidate
            } else {
                pieces.append(current)
                current = w
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    private static func wrapResolvedByWords(
        _ text: String,
        maxPhonemes: Int,
        phonemeCount: (String) -> Int
    ) -> [String] {
        var pieces: [String] = []
        var current = ""

        for word in resolvedWords(in: text) {
            if current.isEmpty {
                current = word
                continue
            }

            let candidate = current + " " + word
            if phonemeCount(candidate) <= maxPhonemes {
                current = candidate
            } else {
                pieces.append(current)
                current = word
            }
        }
        if !current.isEmpty { pieces.append(current) }
        return pieces
    }

    private static func resolvedWords(in text: String) -> [String] {
        var words: [String] = []
        var current = ""
        var index = text.startIndex

        func flush() {
            if !current.isEmpty { words.append(current) }
            current = ""
        }

        while index < text.endIndex {
            if let link = MisakiPronunciationMarkup.link(in: text, startingAt: index) {
                current.append(contentsOf: text[link.range])
                index = link.range.upperBound
                continue
            }

            let character = text[index]
            if character.isWhitespace {
                flush()
            } else {
                current.append(character)
            }
            index = text.index(after: index)
        }
        flush()

        return words
    }

    /// Hard-splits a single token longer than `maxChars` into fixed-size slices.
    private static func hardSplit(_ word: String, maxChars: Int) -> [String] {
        var pieces: [String] = []
        var idx = word.startIndex
        while idx < word.endIndex {
            let end = word.index(idx, offsetBy: maxChars, limitedBy: word.endIndex) ?? word.endIndex
            pieces.append(String(word[idx..<end]))
            idx = end
        }
        return pieces
    }
}
