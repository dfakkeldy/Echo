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
    nonisolated private static let linkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue)

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
        var boundaryPending = false
        let chars = Array(text)
        for i in chars.indices {
            let ch = chars[i]
            if boundaryPending, !inLink, ch.isWhitespace {
                flush()
                boundaryPending = false
                continue
            }
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
                boundaryPending = true
            }
        }
        flush()

        return units
    }

    private static func normalizeResolvedText(_ text: String) -> String {
        var normalized = ""
        var index = text.startIndex
        var needsSpace = false
        let markdownRanges = markdownProtectedRangesByStart(in: text)

        while index < text.endIndex {
            if let link = MisakiPronunciationMarkup.link(in: text, startingAt: index) {
                if needsSpace, !normalized.isEmpty { normalized.append(" ") }
                normalized.append(contentsOf: text[link.range])
                needsSpace = false
                index = link.range.upperBound
                continue
            }
            if let linkRange = markdownRanges[index] {
                if needsSpace, !normalized.isEmpty { normalized.append(" ") }
                normalized.append(contentsOf: text[linkRange])
                needsSpace = false
                index = linkRange.upperBound
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
        var boundaryPending = false
        let characters = Array(text)
        let markdownRanges = markdownProtectedRangesByStart(in: text)

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
            if let linkRange = markdownRanges[textIndex] {
                current.append(contentsOf: text[linkRange])
                characterIndex += text[linkRange].count
                textIndex = linkRange.upperBound
                continue
            }

            let character = text[textIndex]
            if boundaryPending, character.isWhitespace {
                flush()
                boundaryPending = false
                characterIndex += 1
                textIndex = text.index(after: textIndex)
                continue
            }
            current.append(character)
            if isBoundary(character, characterIndex, characters) {
                boundaryPending = true
            }
            characterIndex += 1
            textIndex = text.index(after: textIndex)
        }
        flush()

        return units
    }

    private struct MarkdownLabel {
        let range: Range<String.Index>
        let contentRange: Range<String.Index>
    }

    /// Returns one complete inline Markdown link. Both label brackets and
    /// destination parentheses are balanced, and escaped delimiters do not
    /// affect nesting.
    nonisolated static func markdownInlineLinkRange(
        in source: String,
        startingAt start: String.Index
    ) -> Range<String.Index>? {
        guard let label = markdownLabel(in: source, startingAt: start) else {
            return nil
        }
        let openParenthesis = label.range.upperBound
        guard openParenthesis < source.endIndex, source[openParenthesis] == "(" else {
            return nil
        }

        guard let destination = balancedRange(
            in: source,
            startingAt: openParenthesis,
            opening: "(",
            closing: ")")
        else { return nil }
        return start..<destination.upperBound
    }

    /// Complete source spans that pronunciation rewriters must never alter.
    /// Markdown parsing owns inline links and definition-aware reference forms;
    /// Foundation link detection conservatively covers scheme and scheme-less
    /// plain URLs.
    nonisolated static func pronunciationProtectedRanges(
        in source: String
    ) -> [Range<String.Index>] {
        var ranges = markdownProtectedRanges(in: source)

        if let linkDetector {
            let fullRange = NSRange(source.startIndex..., in: source)
            ranges.append(
                contentsOf: linkDetector.matches(in: source, range: fullRange).compactMap {
                    result in
                    guard result.resultType == .link else { return nil }
                    return Range(result.range, in: source)
                })
        }
        return ranges
    }

    /// Markdown syntax that must stay atomic during both pronunciation
    /// resolution and resolved-text chunking. Shortcut references are protected
    /// only when a matching definition exists in the same source.
    nonisolated static func markdownProtectedRanges(
        in source: String
    ) -> [Range<String.Index>] {
        let definitions = markdownReferenceDefinitions(in: source)
        let definitionRanges = Dictionary(
            uniqueKeysWithValues: definitions.ranges.map {
                ($0.lowerBound, $0)
            })
        var ranges = definitions.ranges
        var index = source.startIndex

        while index < source.endIndex {
            if let definition = definitionRanges[index] {
                index = definition.upperBound
                continue
            }
            guard source[index] == "[",
                let label = markdownLabel(in: source, startingAt: index)
            else {
                index = source.index(after: index)
                continue
            }

            if let inlineRange = markdownInlineLinkRange(in: source, startingAt: index) {
                ranges.append(inlineRange)
                index = inlineRange.upperBound
                continue
            }

            let next = label.range.upperBound
            if next < source.endIndex, source[next] == "[",
                let reference = markdownLabel(in: source, startingAt: next)
            {
                let referenceID =
                    reference.contentRange.isEmpty
                    ? normalizedMarkdownReference(
                        source[label.contentRange])
                    : normalizedMarkdownReference(
                        source[reference.contentRange])
                if definitions.ids.contains(referenceID) {
                    let range = index..<reference.range.upperBound
                    ranges.append(range)
                    index = range.upperBound
                    continue
                }
            } else {
                let shortcutID = normalizedMarkdownReference(
                    source[label.contentRange])
                if definitions.ids.contains(shortcutID) {
                    ranges.append(label.range)
                    index = label.range.upperBound
                    continue
                }
            }
            index = source.index(after: index)
        }

        return ranges.sorted { $0.lowerBound < $1.lowerBound }
    }

    private nonisolated static func markdownProtectedRangesByStart(
        in source: String
    ) -> [String.Index: Range<String.Index>] {
        Dictionary(
            uniqueKeysWithValues: markdownProtectedRanges(in: source).map {
                ($0.lowerBound, $0)
            })
    }

    private nonisolated static func markdownReferenceDefinitions(
        in source: String
    ) -> (ids: Set<String>, ranges: [Range<String.Index>]) {
        var ids: Set<String> = []
        var ranges: [Range<String.Index>] = []
        var lineStart = source.startIndex

        while lineStart < source.endIndex {
            let lineEnd =
                source[lineStart...].firstIndex(where: { $0.isNewline })
                ?? source.endIndex
            var contentStart = lineStart
            var indentation = 0
            while contentStart < lineEnd,
                source[contentStart] == " ",
                indentation < 3
            {
                indentation += 1
                contentStart = source.index(after: contentStart)
            }

            if contentStart < lineEnd,
                let label = markdownLabel(in: source, startingAt: contentStart),
                label.range.upperBound < lineEnd,
                source[label.range.upperBound] == ":"
            {
                let referenceID = normalizedMarkdownReference(
                    source[label.contentRange])
                if !referenceID.isEmpty {
                    ids.insert(referenceID)
                    ranges.append(lineStart..<lineEnd)
                }
            }

            guard lineEnd < source.endIndex else { break }
            lineStart = source.index(after: lineEnd)
        }
        return (ids, ranges)
    }

    private nonisolated static func markdownLabel(
        in source: String,
        startingAt start: String.Index
    ) -> MarkdownLabel? {
        guard start < source.endIndex, source[start] == "[",
            let range = balancedRange(
                in: source,
                startingAt: start,
                opening: "[",
                closing: "]")
        else { return nil }
        let contentStart = source.index(after: range.lowerBound)
        let contentEnd = source.index(before: range.upperBound)
        return MarkdownLabel(
            range: range,
            contentRange: contentStart..<contentEnd)
    }

    private nonisolated static func balancedRange(
        in source: String,
        startingAt start: String.Index,
        opening: Character,
        closing: Character
    ) -> Range<String.Index>? {
        guard start < source.endIndex, source[start] == opening else {
            return nil
        }
        var depth = 1
        var index = source.index(after: start)
        while index < source.endIndex {
            if source[index] == "\\" {
                let escaped = source.index(after: index)
                index =
                    escaped < source.endIndex
                    ? source.index(after: escaped)
                    : escaped
                continue
            }
            if source[index] == opening {
                depth += 1
            } else if source[index] == closing {
                depth -= 1
                if depth == 0 {
                    return start..<source.index(after: index)
                }
            }
            index = source.index(after: index)
        }
        return nil
    }

    private nonisolated static func normalizedMarkdownReference(
        _ source: Substring
    ) -> String {
        var unescaped = ""
        var index = source.startIndex
        while index < source.endIndex {
            if source[index] == "\\" {
                let escaped = source.index(after: index)
                if escaped < source.endIndex {
                    unescaped.append(source[escaped])
                    index = source.index(after: escaped)
                    continue
                }
            }
            unescaped.append(source[index])
            index = source.index(after: index)
        }
        return unescaped.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .lowercased()
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
    nonisolated static func isSentenceBoundary(
        _ ch: Character,
        at index: Int,
        in chars: [Character]
    )
        -> Bool
    {
        if ch == "." {
            return !hasAlphanumericNeighbors(at: index, in: chars)
        }
        return ch == "!" || ch == "?"
    }

    /// Tier 2: in-sentence clause marks, used only to break a single over-long
    /// sentence. `,`/`:` are ignored when they sit between digits (e.g. `3,000`,
    /// `12:30`) so numbers and times aren't split mid-token.
    nonisolated static func isClauseBoundary(
        _ ch: Character,
        at index: Int,
        in chars: [Character]
    )
        -> Bool
    {
        if ch == ";" { return true }
        if ch == "," || ch == ":" {
            return !hasDigitNeighbor(at: index, in: chars)
        }
        return false
    }

    private nonisolated static func hasDigitNeighbor(
        at index: Int,
        in chars: [Character]
    ) -> Bool {
        let hasPreviousDigit = index > chars.startIndex && chars[index - 1].isNumber
        let nextIndex = index + 1
        let hasNextDigit = nextIndex < chars.endIndex && chars[nextIndex].isNumber
        return hasPreviousDigit && hasNextDigit
    }

    private nonisolated static func hasAlphanumericNeighbors(
        at index: Int,
        in chars: [Character]
    ) -> Bool {
        let hasPreviousAlphanumeric =
            index > chars.startIndex
            && (chars[index - 1].isLetter || chars[index - 1].isNumber)
        let nextIndex = index + 1
        let hasNextAlphanumeric =
            nextIndex < chars.endIndex
            && (chars[nextIndex].isLetter || chars[nextIndex].isNumber)
        return hasPreviousAlphanumeric && hasNextAlphanumeric
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
        let markdownRanges = markdownProtectedRangesByStart(in: text)

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
            if let linkRange = markdownRanges[index] {
                current.append(contentsOf: text[linkRange])
                index = linkRange.upperBound
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
