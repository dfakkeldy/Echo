// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import Echo

@Suite struct HomographPronunciationResolverTests {
    @Test func resolvesPastTenseReadFromTemporalContext() {
        let out = HomographPronunciationResolver.apply(to: "I read the book yesterday.")

        #expect(out == "I [read](/ɹˈɛd/) the book yesterday.")
    }

    @Test func resolvesPassiveReadAfterBeAuxiliary() {
        let out = HomographPronunciationResolver.apply(to: "The book was read aloud.")

        #expect(out == "The book was [read](/ɹˈɛd/) aloud.")
    }

    @Test func leavesPresentTenseReadUnchanged() {
        #expect(
            HomographPronunciationResolver.apply(to: "I will read the book.")
                == "I will read the book.")
        #expect(HomographPronunciationResolver.apply(to: "I read every day.") == "I read every day.")
    }

    @Test func resolvesLiveVerbAndAdjectiveContexts() {
        #expect(
            HomographPronunciationResolver.apply(to: "They live nearby.")
                == "They [live](/lˈɪv/) nearby.")
        #expect(
            HomographPronunciationResolver.apply(to: "It was a live show.")
                == "It was a [live](/lˈIv/) show.")
    }

    @Test func resolvesLivesVerbAndNounContexts() {
        #expect(
            HomographPronunciationResolver.apply(to: "She lives in Halifax.")
                == "She [lives](/lˈɪvz/) in Halifax.")
        #expect(
            HomographPronunciationResolver.apply(to: "Their lives changed.")
                == "Their [lives](/lˈIvz/) changed.")
    }

    @Test func doesNotRewriteHyphenatedCompounds() {
        let text = "This is a read-only live-in setup."

        #expect(HomographPronunciationResolver.apply(to: text) == text)
    }

    @Test func existingPronunciationOverrideWins() {
        let overridden = PronunciationOverrides(entries: ["read": "ɹˈid"])
            .apply(to: "I read the book yesterday.")

        #expect(
            HomographPronunciationResolver.apply(to: overridden)
                == "I [read](/ɹˈid/) the book yesterday.")
    }

    @Test func resolvedLinksReachG2PAsExactPhonemes() {
        let text = HomographPronunciationResolver.apply(to: "I read the book yesterday.")
        let phonemes = KokoroG2P().phonemes(for: text)

        #expect(phonemes.contains("ɹˈɛd"))
    }
}
