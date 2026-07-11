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
        let isAuthoredLinkDisplay: Bool
        /// True when this token opens a new sentence (nothing but a sentence
        /// terminator or the start of the text precedes it). Lets the contextual
        /// rules avoid reading across sentence boundaries that the word tokenizer
        /// otherwise ignores.
        let startsSentence: Bool
    }

    private enum IPA {
        static let readPast = "ɹˈɛd"
        static let liveAdjective = "lˈIv"
        static let liveVerb = "lˈɪv"
        static let livesNoun = "lˈIvz"
        static let livesVerb = "lˈɪvz"
        static let recordNoun = "ɹˈɛkəɹd"
        static let recordVerb = "ɹəkˈɔɹd"
        static let contentNoun = "kˈɑntɛnt"
        static let contentSatisfied = "kəntˈɛnt"
        static let resumeDocument = "ɹˈɛzʊmˌA"
        static let resumesDocuments = "ɹˈɛzʊmˌAz"
        static let arithmeticNoun = "əɹˈɪθmətˌɪk"
    }

    private static let wordRegex = try! NSRegularExpression(pattern: #"\b[\p{L}]+\b"#)
    private static let hyphens: Set<Character> = ["-", "‑"]
    private static let sentenceTerminators: Set<Character> = [
        ".", "!", "?", "…", ";", "\n", "\r",
    ]

    private static let pastReadPreceders: Set<String> = [
        "am", "are", "be", "been", "being", "get", "gets", "got", "gotten",
        "had", "has", "have", "having", "is", "was", "were",
    ]
    private static let pastReadFollowers: Set<String> = [
        "ago", "already", "earlier", "last", "previously", "yesterday",
    ]

    private static let liveVerbPreceders: Set<String> = [
        "can", "children", "could", "i", "may", "might", "must", "people", "readers",
        "shall", "should", "they", "to", "we", "will", "would", "you",
    ]
    private static let liveVerbFollowers: Set<String> = [
        "alone", "at", "downtown", "elsewhere", "forever", "here", "in", "inside",
        "longer", "near", "nearby", "on", "outside", "there", "together", "upstairs",
        "well", "with",
    ]
    private static let liveAdjectiveFollowers: Set<String> = [
        "asset", "assets", "audience", "broadcast", "broadcasts", "content", "coverage",
        "demo", "demos", "event", "events", "feed", "feeds", "lesson", "lessons",
        "lecture", "lectures", "music", "performance", "performances", "recording",
        "recordings", "session", "sessions", "show", "shows", "stream", "streams",
        "update", "updates", "wire", "wires",
    ]

    private static let livesNounPreceders: Set<String> = [
        "all", "her", "his", "many", "my", "our", "several", "their", "these",
        "those", "whose", "your",
    ]
    private static let livesVerbPreceders: Set<String> = [
        "everyone", "he", "it", "nobody", "one", "she", "somebody", "someone",
        "that", "who", "receipt",
    ]

    private static let recordNounPreceders: Set<String> = [
        "a", "an", "another", "each", "every", "her", "his", "its", "my", "our",
        "that", "the", "their", "these", "this", "those", "your",
    ]
    private static let recordNounCompoundFollowers: Set<String> = [
        "label", "labels", "player", "players", "sales", "store", "stores",
    ]
    private static let recordVerbPreceders: Set<String> = [
        "can", "could", "may", "might", "must", "please", "shall", "should", "to", "will",
        "would",
    ]

    private static let contentNounPreceders: Set<String> = [
        "all", "any", "app", "audio", "book", "chapter", "course", "digital", "educational",
        "her", "his", "its", "more", "my", "new", "our", "page", "site", "some",
        "story", "that", "the", "their", "these", "this", "those", "training", "video",
        "web", "your",
    ]
    private static let contentNounFollowers: Set<String> = [
        "changed", "includes", "is", "lives", "ships", "shipped", "stayed", "stays",
        "was",
    ]
    private static let contentNounSentenceStartFollowers: Set<String> = [
        "i", "it", "that", "they", "this", "we", "you",
    ]
    private static let contentSatisfiedFollowers: Set<String> = [
        "to", "with",
    ]
    /// Copula / linking verbs that make a following `content` the "satisfied"
    /// adjective ("I am content with…", "she felt content"). Without one of
    /// these a bare "content to"/"content with" is the noun, not the adjective.
    private static let contentAdjectivePreceders: Set<String> = [
        "am", "appear", "appeared", "appears", "are", "be", "became", "become",
        "becomes", "been", "being", "feel", "feeling", "feels", "felt", "is",
        "look", "looked", "looks", "m", "remain", "remained", "remains", "seem",
        "seemed", "seems", "stay", "stayed", "stays", "was", "were",
    ]
    private static let resumeDocumentPreceders: Set<String> = [
        "all", "applicant", "applicants", "candidate", "candidates", "her", "his",
        "many", "my", "our", "several", "the", "their", "these", "those", "your",
    ]
    private static let resumeDocumentFollowers: Set<String> = [
        "attached", "changed", "includes", "is", "lists", "mentions", "shows",
        "submitted", "was",
    ]
    private static let resumesDocumentFollowers: Set<String> = [
        "are", "attached", "include", "list", "mention", "show", "submitted", "were",
    ]
    private static let resumeVerbPreceders: Set<String> = [
        "can", "could", "does", "may", "might", "must", "should", "to", "will",
        "would",
    ]
    private static let arithmeticAdjectiveFollowers: Set<String> = [
        "mean", "means", "operation", "operations", "operator", "operators",
        "progression", "progressions", "sequence", "sequences",
    ]

    static func apply(to text: String) -> String {
        let tokens = tokens(in: text)
        guard !tokens.isEmpty else { return text }

        var result = text
        for index in tokens.indices.reversed() {
            let token = tokens[index]
            guard !token.isAuthoredLinkDisplay else { continue }
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
        case "record":
            return recordIPA(at: index, tokens: tokens)
        case "content":
            return contentIPA(at: index, tokens: tokens)
        case "resume":
            return resumeIPA(at: index, tokens: tokens)
        case "resumes":
            return resumesIPA(at: index, tokens: tokens)
        case "résumé":
            return IPA.resumeDocument
        case "résumés":
            return IPA.resumesDocuments
        case "arithmetic":
            return arithmeticIPA(at: index, tokens: tokens)
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

    private static func contentIPA(at index: Int, tokens: [Token]) -> String? {
        let previous = previousLowercased(tokens, index)
        let next = nextLowercased(tokens, index, limit: 1)

        // A noun preceder ("the content", "audio content") wins outright, even
        // when a "to"/"with" follows: "Add content to the page." is the noun.
        if previous.map(contentNounPreceders.contains) == true {
            return IPA.contentNoun
        }

        // The "satisfied" adjective ("I am content with this narration") only
        // applies when a copula/linking verb precedes *and* a "to"/"with"
        // follows. A following "to"/"with" alone no longer flips the noun.
        if previous.map(contentAdjectivePreceders.contains) == true,
            next.contains(where: contentSatisfiedFollowers.contains)
        {
            return IPA.contentSatisfied
        }

        if next.contains(where: contentNounFollowers.contains) {
            return IPA.contentNoun
        }

        if index == tokens.startIndex,
            next.contains(where: contentNounSentenceStartFollowers.contains)
        {
            return IPA.contentNoun
        }

        return nil
    }

    private static func resumeIPA(at index: Int, tokens: [Token]) -> String? {
        if previousLowercased(tokens, index).map(resumeVerbPreceders.contains) == true {
            return nil
        }

        let next = nextLowercased(tokens, index, limit: 1)
        if previousLowercased(tokens, index).map(resumeDocumentPreceders.contains) == true {
            return IPA.resumeDocument
        }

        if next.contains(where: resumeDocumentFollowers.contains) {
            return IPA.resumeDocument
        }

        return nil
    }

    private static func resumesIPA(at index: Int, tokens: [Token]) -> String? {
        let next = nextLowercased(tokens, index, limit: 1)
        if previousLowercased(tokens, index).map(resumeDocumentPreceders.contains) == true {
            return IPA.resumesDocuments
        }

        if next.contains(where: resumesDocumentFollowers.contains) {
            return IPA.resumesDocuments
        }

        if index == tokens.startIndex, next.isEmpty {
            return IPA.resumesDocuments
        }

        return nil
    }

    private static func arithmeticIPA(at index: Int, tokens: [Token]) -> String? {
        let next = nextLowercased(tokens, index, limit: 1)
        if next.contains(where: arithmeticAdjectiveFollowers.contains) {
            return nil
        }

        return IPA.arithmeticNoun
    }

    private static func liveIPA(at index: Int, tokens: [Token]) -> String? {
        if previousLowercased(tokens, index).map(liveVerbPreceders.contains) == true {
            return IPA.liveVerb
        }

        if nextLowercased(tokens, index, limit: 1).contains(where: liveVerbFollowers.contains) {
            return IPA.liveVerb
        }

        if nextLowercased(tokens, index, limit: 1).contains(where: liveAdjectiveFollowers.contains)
        {
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

    private static func recordIPA(at index: Int, tokens: [Token]) -> String? {
        let previous = previousLowercased(tokens, index)

        // The attributive compound-noun guard ("record sales", "record labels")
        // only applies to a follower in the *same* sentence. Word tokenization
        // ignores punctuation, so without this a period between clauses
        // ("Please record. Players arrived.") would pull the next sentence's
        // noun into the guard and mis-read the verb as the noun.
        let followerIsSameSentenceCompoundNoun: Bool = {
            let followerIndex = tokens.index(after: index)
            guard followerIndex < tokens.endIndex else { return false }
            let follower = tokens[followerIndex]
            guard !follower.startsSentence else { return false }
            return recordNounCompoundFollowers.contains(follower.lowercased)
        }()

        // A strong verb signal immediately before `record` overrides that guard:
        // infinitival "to" ("designed to record sales") or a modal that is not
        // fronting a question ("We will record sales"). A sentence-initial modal
        // is question inversion where "record labels" is the subject, so it keeps
        // the attributive noun ("Should record labels pay artists?"). Requiring
        // `record` itself to be mid-sentence stops a modal in the previous
        // sentence from leaking across a boundary.
        let precederIsVerbSignal: Bool = {
            guard index > tokens.startIndex, !tokens[index].startsSentence else { return false }
            let preceder = tokens[tokens.index(before: index)]
            if preceder.lowercased == "to" { return true }
            return recordVerbPreceders.contains(preceder.lowercased) && !preceder.startsSentence
        }()

        if followerIsSameSentenceCompoundNoun, !precederIsVerbSignal {
            return IPA.recordNoun
        }

        if previous.map(recordNounPreceders.contains) == true {
            return IPA.recordNoun
        }

        if previous.map(recordVerbPreceders.contains) == true {
            return IPA.recordVerb
        }

        return nil
    }

    private static func tokens(in text: String) -> [Token] {
        var result: [Token] = []
        var plainTextStart = text.startIndex
        var index = text.startIndex

        while index < text.endIndex {
            guard let link = MisakiPronunciationMarkup.link(in: text, startingAt: index) else {
                index = text.index(after: index)
                continue
            }

            appendTokens(
                in: plainTextStart..<link.range.lowerBound,
                of: text,
                isAuthoredLinkDisplay: false,
                to: &result)
            appendTokens(
                in: link.displayText.startIndex..<link.displayText.endIndex,
                of: text,
                isAuthoredLinkDisplay: true,
                to: &result)
            index = link.range.upperBound
            plainTextStart = index
        }

        appendTokens(
            in: plainTextStart..<text.endIndex,
            of: text,
            isAuthoredLinkDisplay: false,
            to: &result)
        return result
    }

    private static func appendTokens(
        in searchRange: Range<String.Index>,
        of text: String,
        isAuthoredLinkDisplay: Bool,
        to tokens: inout [Token]
    ) {
        let nsSearchRange = NSRange(searchRange, in: text)
        tokens.append(
            contentsOf: wordRegex.matches(in: text, range: nsSearchRange).compactMap {
                match in
                guard let range = Range(match.range, in: text) else { return nil }
                let value = String(text[range])
                return Token(
                    text: value,
                    lowercased: value.lowercased(),
                    range: range,
                    nsRange: match.range,
                    isAuthoredLinkDisplay: isAuthoredLinkDisplay,
                    startsSentence: startsSentence(before: range, in: text))
            })
    }

    /// Whether `range` begins a new sentence: scanning left from it we reach a
    /// sentence terminator (or the start of the text) before any letter/number.
    private static func startsSentence(before range: Range<String.Index>, in text: String) -> Bool {
        var index = range.lowerBound
        while index > text.startIndex {
            index = text.index(before: index)
            let character = text[index]
            if sentenceTerminators.contains(character) { return true }
            if character.isLetter || character.isNumber { return false }
        }
        return true
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

}
