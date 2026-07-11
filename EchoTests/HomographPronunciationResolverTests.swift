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
        #expect(
            HomographPronunciationResolver.apply(to: "I read every day.") == "I read every day.")
    }

    @Test func resolvesLiveVerbAndAdjectiveContexts() {
        #expect(
            HomographPronunciationResolver.apply(to: "They live nearby.")
                == "They [live](/lˈɪv/) nearby.")
        #expect(
            HomographPronunciationResolver.apply(to: "People live longer with clean audio.")
                == "People [live](/lˈɪv/) longer with clean audio.")
        #expect(
            HomographPronunciationResolver.apply(to: "It was a live show.")
                == "It was a [live](/lˈIv/) show.")
        #expect(
            HomographPronunciationResolver.apply(to: "The live content shipped today.")
                == "The [live](/lˈIv/) [content](/kˈɑntɛnt/) shipped today.")
    }

    @Test func resolvesLivesVerbAndNounContexts() {
        #expect(
            HomographPronunciationResolver.apply(to: "She lives in Halifax.")
                == "She [lives](/lˈɪvz/) in Halifax.")
        #expect(
            HomographPronunciationResolver.apply(to: "The receipt lives in the archive.")
                == "The receipt [lives](/lˈɪvz/) in the archive.")
        #expect(
            HomographPronunciationResolver.apply(to: "The receipt lives securely.")
                == "The receipt [lives](/lˈɪvz/) securely.")
        #expect(
            HomographPronunciationResolver.apply(to: "The author lives alone.")
                == "The author [lives](/lˈɪvz/) alone.")
        #expect(
            HomographPronunciationResolver.apply(to: "Their lives changed.")
                == "Their [lives](/lˈIvz/) changed.")
    }

    @Test func resolvesRecordVerbNounAndCompoundNounContexts() {
        #expect(
            HomographPronunciationResolver.apply(to: "Please record the result.")
                == "Please [record](/ɹəkˈɔɹd/) the result.")
        #expect(
            HomographPronunciationResolver.apply(to: "Review the record before restart.")
                == "Review the [record](/ɹˈɛkəɹd/) before restart.")
        #expect(
            HomographPronunciationResolver.apply(to: "Record sales increased.")
                == "[Record](/ɹˈɛkəɹd/) sales increased.")
        #expect(
            HomographPronunciationResolver.apply(to: "Should record labels pay artists?")
                == "Should [record](/ɹˈɛkəɹd/) labels pay artists?")
    }

    @Test func recordRulesStayNarrowAndRespectCompoundPrecedence() {
        #expect(
            HomographPronunciationResolver.apply(to: "We should record tomorrow.")
                == "We should [record](/ɹəkˈɔɹd/) tomorrow.")
        #expect(
            HomographPronunciationResolver.apply(to: "We need to record tomorrow.")
                == "We need to [record](/ɹəkˈɔɹd/) tomorrow.")
        #expect(
            HomographPronunciationResolver.apply(to: "A record player waits nearby.")
                == "A [record](/ɹˈɛkəɹd/) player waits nearby.")
        #expect(
            HomographPronunciationResolver.apply(to: "Could record stores survive?")
                == "Could [record](/ɹˈɛkəɹd/) stores survive?")
        #expect(
            HomographPronunciationResolver.apply(to: "This recording is clear.")
                == "This recording is clear.")
    }

    @Test func resolvesContentNounAndSatisfiedContexts() {
        #expect(
            HomographPronunciationResolver.apply(to: "Content I found useful stayed here.")
                == "[Content](/kˈɑntɛnt/) I found useful stayed here.")
        #expect(
            HomographPronunciationResolver.apply(to: "The audio content shipped today.")
                == "The audio [content](/kˈɑntɛnt/) shipped today.")
        #expect(
            HomographPronunciationResolver.apply(to: "I am content with this narration.")
                == "I am [content](/kəntˈɛnt/) with this narration.")
    }

    @Test func resolvesResumeDocumentContextsWithoutBreakingVerbContexts() {
        #expect(
            HomographPronunciationResolver.apply(to: "The resumes are attached.")
                == "The [resumes](/ɹˈɛzʊmˌAz/) are attached.")
        #expect(
            HomographPronunciationResolver.apply(to: "Resumes.")
                == "[Resumes](/ɹˈɛzʊmˌAz/).")
        #expect(
            HomographPronunciationResolver.apply(to: "The book resumes here.")
                == "The book resumes here.")
        #expect(
            HomographPronunciationResolver.apply(to: "Playback will resume shortly.")
                == "Playback will resume shortly.")
    }

    @Test func resolvesAccentedResumeDocuments() {
        #expect(
            HomographPronunciationResolver.apply(to: "Her résumé is attached.")
                == "Her [résumé](/ɹˈɛzʊmˌA/) is attached.")
        #expect(
            HomographPronunciationResolver.apply(to: "The résumés were submitted.")
                == "The [résumés](/ɹˈɛzʊmˌAz/) were submitted.")
    }

    @Test func resolvesArithmeticNounStressButKeepsTechnicalAdjectiveContexts() {
        #expect(
            HomographPronunciationResolver.apply(to: "Arithmetic is hard.")
                == "[Arithmetic](/əɹˈɪθmətˌɪk/) is hard.")
        #expect(
            HomographPronunciationResolver.apply(to: "The arithmetic mean is useful.")
                == "The arithmetic mean is useful.")
    }

    @Test func doesNotRewriteHyphenatedCompounds() {
        let text = "This is a read-only live-in record-breaking setup."

        #expect(HomographPronunciationResolver.apply(to: text) == text)
    }

    @Test func existingPronunciationOverrideWins() {
        let overridden = PronunciationOverrides(entries: ["read": "ɹˈid"])
            .apply(to: "I read the book yesterday.")

        #expect(
            HomographPronunciationResolver.apply(to: overridden)
                == "I [read](/ɹˈid/) the book yesterday.")
    }

    @Test func authoredRecordLinkWinsOverContextualRules() {
        let text = "Please [record](/ɹˈɛkəɹd/) the result."

        #expect(HomographPronunciationResolver.apply(to: text) == text)
    }

    @Test func resolvedLinksReachG2PAsExactPhonemes() {
        let text = HomographPronunciationResolver.apply(to: "I read the book yesterday.")
        let phonemes = KokoroG2P().phonemes(for: text)

        #expect(phonemes.contains("ɹˈɛd"))
    }

    @Test func reportedEasyWordRepairsReachG2PAsExactPhonemes() {
        let text = HomographPronunciationResolver.apply(
            to: "The resumes are attached. Arithmetic is hard.")
        let phonemes = KokoroG2P().phonemes(for: text)

        #expect(phonemes.contains("ɹˈɛzʊmˌAz"))
        #expect(phonemes.contains("əɹˈɪθmətˌɪk"))
    }
}
