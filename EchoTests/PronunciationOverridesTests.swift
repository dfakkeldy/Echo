// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct PronunciationOverridesTests {

    @Test func structuredRewriteCarriesScopedDictionaryEvidence() throws {
        let overrides = PronunciationOverrides(entries: [
            "Kubernetes": "kuːbərˈnɛtɪs"
        ])

        let result = overrides.rewrite(
            to: "Deploy Kubernetes today.",
            blockID: "block-7")
        let decision = try #require(result.decisionSeeds.first)

        #expect(result.text == overrides.apply(to: "Deploy Kubernetes today."))
        #expect(decision.blockID == "block-7")
        #expect(decision.wordStart == 1)
        #expect(decision.wordEnd == 1)
        #expect(decision.normalizedWord == "kubernetes")
        #expect(decision.sourceWord == "Kubernetes")
        #expect(decision.sourceContext == "Deploy Kubernetes today.")
        #expect(decision.selectedIPA == "kuːbərˈnɛtɪs")
        #expect(decision.source == .globalOverride)
        #expect(decision.ruleID == "override.global.kubernetes")
        #expect(decision.rationale == "Global override matched “Kubernetes”.")
    }

    @Test func rewritesWholeWordOnly() throws {
        let ovr = PronunciationOverrides(entries: [
            "Kubernetes": "kuːbərˈnɛtɪs"
        ])
        let out = ovr.apply(to: "Deploying Kubernetes to production.")
        #expect(out == "Deploying [Kubernetes](/kuːbərˈnɛtɪs/) to production.")
    }

    @Test func doesNotRewriteSubstrings() throws {
        // "use" must not match inside "user" or "reuse".
        let ovr = PronunciationOverrides(entries: ["use": "juːz"])
        let out = ovr.apply(to: "the user reuses tokens")
        #expect(!out.contains("[user]"))
        #expect(!out.contains("[reuses]"))
    }

    @Test func caseInsensitiveMatch() throws {
        let ovr = PronunciationOverrides(entries: ["postgres": "ˈpɒstɡrɛs"])
        let out = ovr.apply(to: "Postgres and POSTGRES both match.")
        #expect(out.contains("[Postgres](/ˈpɒstɡrɛs/)"))
        #expect(out.contains("[POSTGRES](/ˈpɒstɡrɛs/)"))
    }

    @Test func mergesGlobalAndPerBookBookWins() throws {
        let ovr = PronunciationOverrides.merging(
            global: ["docker": "ˈdɒkə"],
            book: ["docker": "ˈdɑkər"])
        #expect(ovr.entries["docker"] == "ˈdɑkər")  // book overrides global
    }

    @Test func mergingPreservesWinningBookScopeMetadata() throws {
        let global = PronunciationOverrides(entries: ["docker": "ˈdɒkə"])
        let merged = PronunciationOverrides.merging(
            global: global,
            book: ["docker": "ˈdɑkər"])

        let decision = try #require(
            merged.rewrite(to: "Docker ships.", blockID: "b").decisionSeeds.first)
        #expect(decision.source == .bookOverride)
        #expect(decision.ruleID == "override.book.docker")
        #expect(decision.selectedIPA == "ˈdɑkər")
    }

    @Test func emptyOverridesAreNoOp() throws {
        let ovr = PronunciationOverrides(entries: [:])
        let original = "Nothing changes here."
        #expect(ovr.apply(to: original) == original)
    }

    @Test func alreadyLinkedTextIsNotDoubleWrapped() throws {
        // If the source already contains a Misaki link, don't re-wrap.
        let ovr = PronunciationOverrides(entries: ["Kokoro": "kˈOkəɹO"])
        let out = ovr.apply(to: "[Kokoro](/kˈOkəɹO/) models")
        #expect(out == "[Kokoro](/kˈOkəɹO/) models")  // unchanged
    }

    @Test func reOverrideDoesNotCorruptContractions() throws {
        let out = PronunciationOverrides.withBuiltInDefaults([:]).apply(
            to: "you're we're they’re and re-rendered all survived.")

        #expect(out.contains("you're"))
        #expect(out.contains("we're"))
        #expect(out.contains("they’re"))
        #expect(!out.contains("[re](/ɹi/)'"))
        #expect(out.contains("[re](/ɹi/)-rendered"))
    }

    @Test func quotedWordsStillReceiveOverrides() throws {
        let ovr = PronunciationOverrides(entries: [
            "Kubernetes": "kuːbərˈnɛtɪs",
            "Fakkeldy": "fˈækəldi",
        ])

        let out = ovr.apply(to: "Say 'Kubernetes' and ’Fakkeldy’ clearly.")

        #expect(out.contains("'[Kubernetes](/kuːbərˈnɛtɪs/)'"))
        #expect(out.contains("’[Fakkeldy](/fˈækəldi/)’"))
    }

    @Test func builtInCompatibilityWordsUseApprovedPronunciations() {
        let out = PronunciationOverrides.withBuiltInDefaults([:]).apply(
            to: "The process is startable. The filesystem stores the verified result.")

        #expect(out.contains("[startable](/stˈɑɹɾəbəl/)"))
        #expect(out.contains("[filesystem](/fˈIl sˌɪstəm/)"))
        #expect(out.contains("verified"))
        #expect(!out.contains("[verified]"))
    }

    @Test func superFamilyUsesApprovedLongUPronunciations() {
        let out = PronunciationOverrides.withBuiltInDefaults([:]).apply(
            to: "super superhuman superposition supercomputer supercomputers "
                + "superforecasters superimposed superintelligence supernatural "
                + "supervised supervising unsupervised superiority")

        #expect(out.contains("[super](/sˈuːpɚ/)"))
        #expect(out.contains("[superhuman](/sˌuːpɚhjˈumən/)"))
        #expect(out.contains("[superposition](/sˌuːpɚpəzˈɪʃən/)"))
        #expect(out.contains("[supercomputer](/sˌuːpɚkəmpjˈuɾəɹ/)"))
        #expect(out.contains("[supercomputers](/sˌuːpɚkəmpjˈuɾəɹz/)"))
        #expect(out.contains("[superforecasters](/sˌuːpɚfˈɔɹkˌæstəɹz/)"))
        #expect(out.contains("[superimposed](/sˌuːpɚɪmpˈOzd/)"))
        #expect(out.contains("[superintelligence](/sˌuːpɚɪntˈɛləʤᵊns/)"))
        #expect(out.contains("[supernatural](/sˌuːpɚnˈæʧəɹəl/)"))
        #expect(out.contains("[supervised](/sˈuːpɚvˌIzd/)"))
        #expect(out.contains("[supervising](/sˈuːpɚvˌIzɪŋ/)"))
        #expect(out.contains("[unsupervised](/ˌʌnsˈuːpɚvˌIzd/)"))
        #expect(out.hasSuffix(" superiority"))
    }

    @Test func userEntriesOverrideCompatibilityWordsCaseInsensitively() {
        let out = PronunciationOverrides.withBuiltInDefaults([
            "STARTABLE": "stˈɑɹtəbəl",
            "FileSystem": "fˈaɪl sˌɪstəm",
        ]).apply(to: "startable filesystem")

        #expect(out == "[startable](/stˈɑɹtəbəl/) [filesystem](/fˈaɪl sˌɪstəm/)")
    }
}
