// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Applies narrow, deterministic pronunciation hints for English homographs that
/// the lexicon cannot reliably disambiguate from local part-of-speech tags alone.
nonisolated enum HomographPronunciationResolver {
    private struct Token {
        let text: String
        let lowercased: String
        let range: Range<String.Index>
        let nsRange: NSRange
    }

    private enum IPA {
        static let readPast = "ɹˈɛd"
        static let liveAdjective = "lˈIv"
        static let liveVerb = "lˈɪv"
        static let livesNoun = "lˈIvz"
        static let livesVerb = "lˈɪvz"
    }

    private static let wordRegex = try! NSRegularExpression(pattern: #"\b[\p{L}]+\b"#)
    private static let hyphens: Set<Character> = ["-", "‑"]

    private static let pastReadPreceders: Set<String> = [
        "am", "are", "be", "been", "being", "get", "gets", "got", "gotten",
        "had", "has", "have", "having", "is", "was", "were",
    ]
    private static let pastReadFollowers: Set<String> = [
        "ago", "already", "earlier", "last", "previously", "yesterday",
    ]

    private static let liveVerbPreceders: Set<String> = [
        "can", "could", "i", "may", "might", "must", "shall", "should", "they",
        "to", "we", "will", "would", "you",
    ]
    private static let liveVerbFollowers: Set<String> = [
        "at", "here", "in", "near", "nearby", "on", "there", "together", "with",
    ]
    private static let liveAdjectiveFollowers: Set<String> = [
        "audience", "broadcast", "broadcasts", "coverage", "demo", "demos",
        "event", "events", "feed", "feeds", "music", "performance",
        "performances", "recording", "recordings", "show", "shows", "stream",
        "streams", "wire", "wires",
    ]

    private static let livesNounPreceders: Set<String> = [
        "all", "her", "his", "many", "my", "our", "several", "their", "these",
        "those", "whose", "your",
    ]
    private static let livesVerbPreceders: Set<String> = [
        "everyone", "he", "it", "nobody", "one", "she", "somebody", "someone",
        "that", "who",
    ]

    static func apply(to text: String) -> String {
        let tokens = tokens(in: text)
        guard !tokens.isEmpty else { return text }

        var result = text
        for index in tokens.indices.reversed() {
            let token = tokens[index]
            guard !isInsideMisakiLinkDisplay(token.range, in: text) else { continue }
            guard !isHyphenated(token.range, in: text) else { continue }
            guard let ipa = ipa(for: token, at: index, tokens: tokens) else { continue }
            guard let range = Range(token.nsRange, in: result) else { continue }

            result.replaceSubrange(range, with: "[\(token.text)](/\(ipa)/)")
        }
        return result
    }

    private static func ipa(for token: Token, at index: Int, tokens: [Token]) -> String? {
        switch token.lowercased {
        case "read":
            return readIPA(at: index, tokens: tokens)
        case "live":
            return liveIPA(at: index, tokens: tokens)
        case "lives":
            return livesIPA(at: index, tokens: tokens)
        default:
            return nil
        }
    }

    private static func readIPA(at index: Int, tokens: [Token]) -> String? {
        if previousLowercased(tokens, index).map(pastReadPreceders.contains) == true {
            return IPA.readPast
        }

        if nextLowercased(tokens, index, limit: 4).contains(where: pastReadFollowers.contains) {
            return IPA.readPast
        }

        return nil
    }

    private static func liveIPA(at index: Int, tokens: [Token]) -> String? {
        if previousLowercased(tokens, index).map(liveVerbPreceders.contains) == true {
            return IPA.liveVerb
        }

        if nextLowercased(tokens, index, limit: 1).contains(where: liveVerbFollowers.contains) {
            return IPA.liveVerb
        }

        if nextLowercased(tokens, index, limit: 1).contains(where: liveAdjectiveFollowers.contains) {
            return IPA.liveAdjective
        }

        return nil
    }

    private static func livesIPA(at index: Int, tokens: [Token]) -> String? {
        if previousLowercased(tokens, index).map(livesNounPreceders.contains) == true {
            return IPA.livesNoun
        }

        if previousLowercased(tokens, index).map(livesVerbPreceders.contains) == true {
            return IPA.livesVerb
        }

        if nextLowercased(tokens, index, limit: 1).contains(where: liveVerbFollowers.contains) {
            return IPA.livesVerb
        }

        return nil
    }

    private static func tokens(in text: String) -> [Token] {
        let fullRange = NSRange(location: 0, length: (text as NSString).length)
        return wordRegex.matches(in: text, range: fullRange).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let value = String(text[range])
            return Token(text: value, lowercased: value.lowercased(), range: range, nsRange: match.range)
        }
    }

    private static func previousLowercased(_ tokens: [Token], _ index: Int) -> String? {
        guard index > tokens.startIndex else { return nil }
        return tokens[tokens.index(before: index)].lowercased
    }

    private static func nextLowercased(_ tokens: [Token], _ index: Int, limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        let start = tokens.index(after: index)
        guard start < tokens.endIndex else { return [] }
        let end = min(tokens.endIndex, start + limit)
        return tokens[start..<end].map(\.lowercased)
    }

    private static func isHyphenated(_ range: Range<String.Index>, in text: String) -> Bool {
        if range.lowerBound > text.startIndex {
            let previous = text[text.index(before: range.lowerBound)]
            if hyphens.contains(previous) { return true }
        }

        if range.upperBound < text.endIndex {
            let next = text[range.upperBound]
            if hyphens.contains(next) { return true }
        }

        return false
    }

    private static func isInsideMisakiLinkDisplay(_ range: Range<String.Index>, in text: String)
        -> Bool
    {
        var index = range.lowerBound
        while index > text.startIndex {
            index = text.index(before: index)
            if text[index] == "]" { return false }
            if text[index] == "[" { return true }
        }
        return false
    }
}
