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
        var preserveFollowingLineBreak = false
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
                preserveFollowingLineBreak = text[linkRange].contains {
                    $0.isNewline
                }
                needsSpace = false
                index = linkRange.upperBound
                continue
            }

            let character = text[index]
            if character.isWhitespace {
                if preserveFollowingLineBreak, character.isNewline {
                    normalized.append(character)
                    needsSpace = false
                } else {
                    needsSpace = !normalized.isEmpty
                }
            } else {
                if needsSpace { normalized.append(" ") }
                normalized.append(character)
                needsSpace = false
            }
            preserveFollowingLineBreak = false
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

    private struct MarkdownDefinitions {
        let ids: Set<String>
        let ranges: [Range<String.Index>]
    }

    nonisolated struct PronunciationSyntaxIndex {
        let protectedRanges: [Range<String.Index>]
        let editorialRangeByIndex: [String.Index: Range<String.Index>]
    }

    /// A source-local parser. Its indexes are built in bounded source-wide
    /// passes, then all label, line-recovery, and editorial-containment lookups
    /// are constant-time. Malformed inline syntax recovers only through its
    /// current source line and the caller skips that protected range.
    private nonisolated struct MarkdownParser {
        private enum BareDestinationResult {
            case closedLink(String.Index)
            case stoppedAtWhitespace(String.Index)
            case invalid
        }

        private enum InlineLinkResult {
            case notInline
            case valid(Range<String.Index>)
            case malformed(Range<String.Index>)
        }

        let source: String
        let matchingSquareBracket: [String.Index: String.Index]
        let nestedLabelOpenings: Set<String.Index>
        let outermostSquareBracketRanges: [Range<String.Index>]
        let lineEndByIndex: [String.Index: String.Index]
        private(set) var inspectionCount: Int

        init(source: String) {
            self.source = source
            var matches: [String.Index: String.Index] = [:]
            var stack: [String.Index] = []
            var nestedOpenings: Set<String.Index> = []
            var outermostRanges: [Range<String.Index>] = []
            var inspections = 0
            var index = source.startIndex

            while index < source.endIndex {
                inspections += 1
                if source[index] == "\\" {
                    let escaped = source.index(after: index)
                    if escaped < source.endIndex {
                        inspections += 1
                        index = source.index(after: escaped)
                    } else {
                        index = escaped
                    }
                    continue
                }
                if source[index] == "[" {
                    if let outermost = stack.first {
                        nestedOpenings.insert(outermost)
                    }
                    stack.append(index)
                } else if source[index] == "]", let opening = stack.popLast() {
                    matches[opening] = index
                    if stack.isEmpty {
                        outermostRanges.append(
                            opening..<source.index(after: index))
                    }
                }
                index = source.index(after: index)
            }

            var lineEnds: [String.Index: String.Index] = [:]
            var lineIndices: [String.Index] = []
            index = source.startIndex
            while index < source.endIndex {
                inspections += 1
                lineIndices.append(index)
                if source[index].isNewline {
                    for lineIndex in lineIndices {
                        inspections += 1
                        lineEnds[lineIndex] = index
                    }
                    lineIndices.removeAll(keepingCapacity: true)
                }
                index = source.index(after: index)
            }
            for lineIndex in lineIndices {
                inspections += 1
                lineEnds[lineIndex] = source.endIndex
            }

            matchingSquareBracket = matches
            nestedLabelOpenings = nestedOpenings
            outermostSquareBracketRanges = outermostRanges
            lineEndByIndex = lineEnds
            inspectionCount = inspections
        }

        mutating func parse() -> PronunciationSyntaxIndex {
            let definitions = referenceDefinitions()
            let definitionRangesByStart = Dictionary(
                uniqueKeysWithValues: definitions.ranges.map {
                    ($0.lowerBound, $0)
                })
            var ranges: [Range<String.Index>] = []
            var index = source.startIndex

            while index < source.endIndex {
                if let definition = definitionRangesByStart[index] {
                    ranges.append(definition)
                    index = definition.upperBound
                    continue
                }
                guard inspect(index) == "[", let label = label(at: index) else {
                    index = source.index(after: index)
                    continue
                }

                switch inlineLinkResult(label: label) {
                case .valid(let inlineRange):
                    ranges.append(inlineRange)
                    index = inlineRange.upperBound
                    continue
                case .malformed(let recoveryRange):
                    ranges.append(recoveryRange)
                    index = recoveryRange.upperBound
                    continue
                case .notInline:
                    break
                }

                let next = label.range.upperBound
                if next < source.endIndex, inspect(next) == "[",
                    let reference = self.label(at: next)
                {
                    // Full and collapsed reference syntax stays atomic even
                    // after the chunker narrows to a sentence that no longer
                    // carries the source definition alongside it.
                    let range = index..<reference.range.upperBound
                    ranges.append(range)
                    index = range.upperBound
                    continue
                } else {
                    let shortcutID = normalizedReference(label.contentRange)
                    if definitions.ids.contains(shortcutID) {
                        ranges.append(label.range)
                        index = label.range.upperBound
                        continue
                    }
                }
                if nestedLabelOpenings.contains(index) {
                    // Nested standalone labels are not an editorial rewrite
                    // surface. Conservatively protect the one outer label and
                    // never revisit its overlapping nested labels.
                    ranges.append(label.range)
                }
                index = label.range.upperBound
            }

            var editorialRangeByIndex: [String.Index: Range<String.Index>] = [:]
            var protectedCursor = 0
            for range in outermostSquareBracketRanges {
                let upperBound = range.upperBound
                if upperBound < source.endIndex {
                    let suffix = inspect(upperBound)
                    if suffix == "[" || suffix == "(" {
                        continue
                    }
                }
                while protectedCursor < ranges.count,
                    ranges[protectedCursor].upperBound <= range.lowerBound
                {
                    protectedCursor += 1
                }
                if protectedCursor < ranges.count,
                    ranges[protectedCursor].overlaps(range)
                {
                    continue
                }
                var editorialIndex = range.lowerBound
                while editorialIndex < range.upperBound {
                    inspectionCount += 1
                    editorialRangeByIndex[editorialIndex] = range
                    editorialIndex = source.index(after: editorialIndex)
                }
            }
            return PronunciationSyntaxIndex(
                protectedRanges: ranges,
                editorialRangeByIndex: editorialRangeByIndex)
        }

        mutating func inlineLinkRange(startingAt start: String.Index)
            -> Range<String.Index>?
        {
            guard let label = label(at: start) else { return nil }
            guard case .valid(let range) = inlineLinkResult(label: label) else {
                return nil
            }
            return range
        }

        private mutating func inlineLinkResult(
            label: MarkdownLabel
        ) -> InlineLinkResult {
            let opening = label.range.upperBound
            guard opening < source.endIndex, inspect(opening) == "(" else {
                return .notInline
            }
            let lineEnd = lineEndByIndex[opening] ?? source.endIndex
            guard let upperBound = inlineLinkUpperBound(
                afterOpening: opening,
                before: lineEnd)
            else {
                return .malformed(label.range.lowerBound..<lineEnd)
            }
            return .valid(label.range.lowerBound..<upperBound)
        }

        /// Parses the destination first, then an optional title. Quoted-title
        /// parentheses are literal text and never destination nesting.
        private mutating func inlineLinkUpperBound(
            afterOpening opening: String.Index,
            before limit: String.Index
        ) -> String.Index? {
            var index = source.index(after: opening)
            let hadLeadingWhitespace = skipHorizontalWhitespace(
                &index,
                before: limit)
            guard index < limit else { return nil }

            if inspect(index) == ")" {
                return source.index(after: index)
            }

            if hadLeadingWhitespace, isTitleOpening(inspect(index)) {
                guard let afterTitle = titleUpperBound(
                    startingAt: index,
                    before: limit)
                else { return nil }
                index = afterTitle
                _ = skipHorizontalWhitespace(&index, before: limit)
                guard index < limit, inspect(index) == ")" else {
                    return nil
                }
                return source.index(after: index)
            }

            if inspect(index) == "<" {
                guard let afterDestination = angleDestinationUpperBound(
                    startingAt: index,
                    before: limit)
                else { return nil }
                index = afterDestination
            } else {
                switch bareInlineDestinationResult(
                    startingAt: index,
                    before: limit)
                {
                case .closedLink(let upperBound):
                    return upperBound
                case .stoppedAtWhitespace(let whitespace):
                    index = whitespace
                case .invalid:
                    return nil
                }
            }

            if index < limit, inspect(index) == ")" {
                return source.index(after: index)
            }
            guard skipHorizontalWhitespace(&index, before: limit) else {
                return nil
            }
            if index < limit, inspect(index) == ")" {
                return source.index(after: index)
            }
            guard index < limit, isTitleOpening(inspect(index)),
                let afterTitle = titleUpperBound(
                    startingAt: index,
                    before: limit)
            else { return nil }
            index = afterTitle
            _ = skipHorizontalWhitespace(&index, before: limit)
            guard index < limit, inspect(index) == ")" else {
                return nil
            }
            return source.index(after: index)
        }

        private mutating func bareInlineDestinationResult(
            startingAt start: String.Index,
            before limit: String.Index
        ) -> BareDestinationResult {
            var depth = 0
            var index = start
            while index < limit {
                let character = inspect(index)
                if character == "\\" {
                    guard advancePastEscape(&index, before: limit) else {
                        return .invalid
                    }
                    continue
                }
                if character.isWhitespace, depth == 0 {
                    return .stoppedAtWhitespace(index)
                }
                if character == "<" || character == ">" {
                    return .invalid
                }
                if character == "(" {
                    depth += 1
                } else if character == ")" {
                    if depth == 0 {
                        return .closedLink(source.index(after: index))
                    }
                    depth -= 1
                }
                index = source.index(after: index)
            }
            return .invalid
        }

        private mutating func angleDestinationUpperBound(
            startingAt start: String.Index,
            before limit: String.Index
        ) -> String.Index? {
            guard inspect(start) == "<" else { return nil }
            var index = source.index(after: start)
            while index < limit {
                let character = inspect(index)
                if character == "\\" {
                    guard advancePastEscape(&index, before: limit) else {
                        return nil
                    }
                    continue
                }
                if character == ">" {
                    return source.index(after: index)
                }
                if character == "<" || character.isWhitespace {
                    return nil
                }
                index = source.index(after: index)
            }
            return nil
        }

        private mutating func titleUpperBound(
            startingAt start: String.Index,
            before limit: String.Index
        ) -> String.Index? {
            let opening = inspect(start)
            let closing: Character
            switch opening {
            case "\"": closing = "\""
            case "'": closing = "'"
            case "(": closing = ")"
            default: return nil
            }

            var index = source.index(after: start)
            while index < limit {
                let character = inspect(index)
                if character == "\\" {
                    guard advancePastEscape(&index, before: limit) else {
                        return nil
                    }
                    continue
                }
                if character == closing {
                    return source.index(after: index)
                }
                if opening == "(", character == "(" {
                    return nil
                }
                index = source.index(after: index)
            }
            return nil
        }

        private mutating func referenceDefinitions() -> MarkdownDefinitions {
            var ids: Set<String> = []
            var ranges: [Range<String.Index>] = []
            var lineStart = source.startIndex

            while lineStart < source.endIndex {
                let lineEnd = lineEndByIndex[lineStart] ?? source.endIndex
                if let definition = referenceDefinition(
                    lineStart: lineStart,
                    lineEnd: lineEnd)
                {
                    ids.insert(definition.id)
                    ranges.append(definition.range)
                }
                guard lineEnd < source.endIndex else { break }
                lineStart = source.index(after: lineEnd)
            }
            return MarkdownDefinitions(ids: ids, ranges: ranges)
        }

        private mutating func referenceDefinition(
            lineStart: String.Index,
            lineEnd: String.Index
        ) -> (id: String, range: Range<String.Index>)? {
            var index = lineStart
            var indentation = 0
            while index < lineEnd, inspect(index) == " ", indentation < 3 {
                indentation += 1
                index = source.index(after: index)
            }
            guard let label = label(at: index),
                label.range.upperBound < lineEnd,
                inspect(label.range.upperBound) == ":"
            else { return nil }

            let id = normalizedReference(label.contentRange)
            guard !id.isEmpty else { return nil }

            index = source.index(after: label.range.upperBound)
            _ = skipHorizontalWhitespace(&index, before: lineEnd)
            guard index < lineEnd,
                let destinationEnd = definitionDestinationUpperBound(
                    startingAt: index,
                    before: lineEnd)
            else { return nil }
            index = destinationEnd

            let hadWhitespace = skipHorizontalWhitespace(&index, before: lineEnd)
            if index < lineEnd {
                guard hadWhitespace, isTitleOpening(inspect(index)) else {
                    return nil
                }
                guard let afterTitle = titleUpperBound(
                    startingAt: index,
                    before: lineEnd)
                else {
                    return (id, lineStart..<lineEnd)
                }
                index = afterTitle
                _ = skipHorizontalWhitespace(&index, before: lineEnd)
                guard index == lineEnd else {
                    return (id, lineStart..<lineEnd)
                }
                return (id, lineStart..<lineEnd)
            }

            guard lineEnd < source.endIndex else {
                return (id, lineStart..<lineEnd)
            }
            let nextLineStart = source.index(after: lineEnd)
            let nextLineEnd = lineEndByIndex[nextLineStart] ?? source.endIndex
            var titleStart = nextLineStart
            var titleIndentation = 0
            while titleStart < nextLineEnd,
                inspect(titleStart) == " ",
                titleIndentation < 3
            {
                titleIndentation += 1
                titleStart = source.index(after: titleStart)
            }
            guard titleStart < nextLineEnd,
                isTitleOpening(inspect(titleStart))
            else {
                return (id, lineStart..<lineEnd)
            }
            guard let afterTitle = titleUpperBound(
                startingAt: titleStart,
                before: nextLineEnd)
            else {
                return (id, lineStart..<nextLineEnd)
            }
            var trailing = afterTitle
            _ = skipHorizontalWhitespace(&trailing, before: nextLineEnd)
            guard trailing == nextLineEnd else {
                return (id, lineStart..<nextLineEnd)
            }
            return (id, lineStart..<nextLineEnd)
        }

        private mutating func definitionDestinationUpperBound(
            startingAt start: String.Index,
            before limit: String.Index
        ) -> String.Index? {
            if inspect(start) == "<" {
                return angleDestinationUpperBound(startingAt: start, before: limit)
            }

            var depth = 0
            var index = start
            while index < limit {
                let character = inspect(index)
                if character == "\\" {
                    guard advancePastEscape(&index, before: limit) else {
                        return nil
                    }
                    continue
                }
                if character.isWhitespace {
                    return depth == 0 ? index : nil
                }
                if character == "<" || character == ">" {
                    return nil
                }
                if character == "(" {
                    depth += 1
                } else if character == ")" {
                    guard depth > 0 else { return nil }
                    depth -= 1
                }
                index = source.index(after: index)
            }
            return depth == 0 && index > start ? index : nil
        }

        private mutating func label(at start: String.Index) -> MarkdownLabel? {
            guard start < source.endIndex, inspect(start) == "[",
                let close = matchingSquareBracket[start]
            else { return nil }
            let upperBound = source.index(after: close)
            return MarkdownLabel(
                range: start..<upperBound,
                contentRange: source.index(after: start)..<close)
        }

        @discardableResult
        private mutating func skipHorizontalWhitespace(
            _ index: inout String.Index,
            before limit: String.Index
        ) -> Bool {
            var consumed = false
            while index < limit {
                let character = inspect(index)
                guard character == " " || character == "\t" else { break }
                consumed = true
                index = source.index(after: index)
            }
            return consumed
        }

        private mutating func advancePastEscape(
            _ index: inout String.Index,
            before limit: String.Index
        ) -> Bool {
            let escaped = source.index(after: index)
            guard escaped < limit else {
                index = escaped
                return false
            }
            inspectionCount += 1
            index = source.index(after: escaped)
            return true
        }

        private func isTitleOpening(_ character: Character) -> Bool {
            character == "\"" || character == "'" || character == "("
        }

        private mutating func normalizedReference(
            _ range: Range<String.Index>
        ) -> String {
            var normalized = ""
            var pendingSpace = false
            var index = range.lowerBound
            while index < range.upperBound {
                var character = inspect(index)
                if character == "\\" {
                    let escaped = source.index(after: index)
                    if escaped < range.upperBound {
                        character = inspect(escaped)
                        index = source.index(after: escaped)
                    } else {
                        index = source.index(after: index)
                    }
                } else {
                    index = source.index(after: index)
                }
                if character.isWhitespace {
                    pendingSpace = !normalized.isEmpty
                    continue
                }
                if pendingSpace {
                    normalized.append(" ")
                    pendingSpace = false
                }
                normalized.append(contentsOf: character.lowercased())
            }
            return normalized
        }

        private mutating func inspect(_ index: String.Index) -> Character {
            inspectionCount += 1
            return source[index]
        }
    }

    /// Returns one complete inline Markdown link. Labels use precomputed
    /// escaped-aware matches; the suffix parser separates destination and title
    /// states so literal punctuation inside a quoted title is non-structural.
    nonisolated static func markdownInlineLinkRange(
        in source: String,
        startingAt start: String.Index
    ) -> Range<String.Index>? {
        var parser = MarkdownParser(source: source)
        return parser.inlineLinkRange(startingAt: start)
    }

    /// Complete source spans that pronunciation rewriters must never alter.
    /// Markdown parsing owns inline links and definition-aware reference forms;
    /// Foundation link detection conservatively covers scheme and scheme-less
    /// plain URLs.
    nonisolated static func pronunciationProtectedRanges(
        in source: String
    ) -> [Range<String.Index>] {
        pronunciationSyntaxIndex(in: source).protectedRanges
    }

    nonisolated static func pronunciationSyntaxIndex(
        in source: String
    ) -> PronunciationSyntaxIndex {
        var inspectionCount = 0
        return pronunciationSyntaxIndex(
            in: source,
            inspectionCount: &inspectionCount)
    }

    nonisolated static func pronunciationSyntaxIndex(
        in source: String,
        inspectionCount: inout Int
    ) -> PronunciationSyntaxIndex {
        var parser = MarkdownParser(source: source)
        let markdown = parser.parse()
        var ranges = markdown.protectedRanges
        if let linkDetector {
            let fullRange = NSRange(source.startIndex..., in: source)
            ranges.append(
                contentsOf: linkDetector.matches(in: source, range: fullRange).compactMap {
                    result in
                    guard result.resultType == .link else { return nil }
                    return Range(result.range, in: source)
                })
        }
        inspectionCount = parser.inspectionCount
        return PronunciationSyntaxIndex(
            protectedRanges: ranges,
            editorialRangeByIndex: markdown.editorialRangeByIndex)
    }

    /// Markdown syntax that must stay atomic during both pronunciation
    /// resolution and resolved-text chunking. Shortcut references are protected
    /// only when a matching definition exists in the same source.
    nonisolated static func markdownProtectedRanges(
        in source: String
    ) -> [Range<String.Index>] {
        var parser = MarkdownParser(source: source)
        return parser.parse().protectedRanges
    }

    nonisolated static func markdownProtectedRanges(
        in source: String,
        inspectionCount: inout Int
    ) -> [Range<String.Index>] {
        var parser = MarkdownParser(source: source)
        let ranges = parser.parse().protectedRanges
        inspectionCount = parser.inspectionCount
        return ranges
    }

    private nonisolated static func markdownProtectedRangesByStart(
        in source: String
    ) -> [String.Index: Range<String.Index>] {
        Dictionary(
            uniqueKeysWithValues: markdownProtectedRanges(in: source).map {
                ($0.lowerBound, $0)
            })
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
