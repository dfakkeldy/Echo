import Testing

@testable import MisakiSwift

/// Apple's tagger reads a capitalised sentence-initial heteronym as a noun or
/// adjective even when an object follows, which selects the wrong lexicon entry
/// ("Permit me" → pˈɜɹmɪt). The imperative retag must fix exactly that shape and
/// leave every other reading alone. Every "untouched" pin below was measured
/// to hold before the retag existed, so a failure is a real regression.
@Suite struct ImperativeHeteronymTests {
    private let g2p = EnglishG2P(british: false)

    private func phonemes(of word: String, in sentence: String) -> String? {
        g2p.phonemizeWithMetadata(text: sentence).tokens
            .first { $0.text.lowercased() == word }?.phonemes
    }

    @Test(arguments: [
        ("permit", "Permit me to explain.", "pəɹmˈɪt"),
        ("close", "Close the door.", "klˈOz"),
        ("project", "Project the image on the wall.", "pɹəʤˈɛkt"),
        ("perfect", "Perfect the recipe.", "pəɹfˈɛkt"),
        ("separate", "Separate the eggs.", "sˈɛpəɹˌAt"),
        ("use", "Use it wisely.", "jˈuz"),
        ("escort", "Escort the guest out.", "ɪskˈɔɹt"),
        ("upset", "Upset the balance.", "ˌʌpsˈɛt"),
        ("document", "Document the process.", "dˈɑkjəmˌɛnt"),
        // The tagger calls this one an organization name; the retag still applies.
        ("house", "House them safely.", "hˈWz"),
        // A preceding sentence does not rescue the tagger on its own.
        ("permit", "It was late. Permit me to explain.", "pəɹmˈɪt"),
        ("close", "It was cold. Close the door.", "klˈOz"),
        // Already verbs — must stay verbs.
        ("use", "Use your head.", "jˈuz"),
        ("record", "Record every word.", "ɹəkˈɔɹd"),
        ("produce", "Produce the documents.", "pɹədˈus"),
    ]) func sentenceInitialImperativeReadsAsVerb(word: String, sentence: String, expected: String) {
        #expect(phonemes(of: word, in: sentence) == expected, "\(sentence)")
    }

    @Test(arguments: [
        // Noun used as a modifier: an adjective follows, not an object.
        ("record", "Record high temperatures hit the state.", "ɹˈɛkəɹd"),
        ("record", "Record sales fell.", "ɹˈɛkəɹd"),
        ("permit", "Permit holders may park.", "pˈɜɹmɪt"),
        ("contract", "Contract terms changed.", "kˈɑntɹˌækt"),
        ("project", "Project managers met.", "pɹˈɑʤˌɛkt"),
        ("use", "Use cases vary.", "jˈus"),
        ("use", "Use of force rose.", "jˈus"),
        // Punctuation between the word and the determiner.
        ("record", "Record: the history of jazz.", "ɹˈɛkəɹd"),
        // Preposition follower.
        ("subject", "Subject to change.", "sˈʌbʤɛkt"),
        // Not sentence-initial.
        ("record", "The record shows otherwise.", "ɹˈɛkəɹd"),
        // Bare heading and heading-style pair.
        ("content", "Content", "kˈɑntɛnt"),
        ("project", "Project Overview", "pɹˈɑʤˌɛkt"),
        // Fronted noun + relative clause: a relative marker or subject pronoun follows.
        ("content", "Content that is useful stays.", "kˈɑntɛnt"),
        ("progress", "Progress we made was modest.", "pɹˈɑɡɹəs"),
        ("conduct", "Conduct we expect is simple.", "kˈɑndˌʌkt"),
        ("abuse", "Abuse they suffered was real.", "əbjˈus"),
        // Adjective readings with a noun follower stay adjectives.
        ("live", "Live music played all night.", "lˈIv"),
        ("close", "Close friends arrived.", "klˈOs"),
        ("separate", "Separate rooms were booked.", "sˈɛpəɹət"),
        ("perfect", "Perfect weather held.", "pˈɜɹfəkt"),
        // Not a part-of-speech heteronym in the lexicon.
        ("mark", "Mark the page.", "mˈɑɹk"),
    ]) func nonImperativeShapesAreUntouched(word: String, sentence: String, expected: String) {
        #expect(phonemes(of: word, in: sentence) == expected, "\(sentence)")
    }

    @Test func authoredPronunciationWins() {
        let (phonemes, _) = g2p.phonemize(text: "[Close](/klˈOs/) the door.")
        #expect(phonemes.hasPrefix("klˈOs"), "\(phonemes)")
    }

    @Test func lineBreakBetweenWordAndFollowerDisqualifies() {
        #expect(phonemes(of: "close", in: "Close\nthe door.") == "klˈOs")
    }

    @Test func allCapsTokensAreLeftToTheLexicon() {
        #expect(phonemes(of: "close", in: "CLOSE the door.") == "klˈOs")
    }

    @Test func bothReadingsOfPresentSurvive() {
        let readings = g2p.phonemizeWithMetadata(text: "Present the present.").tokens
            .filter { $0.text.lowercased() == "present" }.compactMap(\.phonemes)
        #expect(readings == ["pɹizˈɛnt", "pɹˈɛzᵊnt"])
    }
}
