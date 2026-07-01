// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// Covers the reported bug: the narrator skipped the author's surname
/// ("Git Happens, by Dan Fakkeldy" → "…by Dan." with "Fakkeldy" dropped).
/// Two guarantees are locked here:
///   1. No OOV word is ever silent — it is voiced, never skipped.
///   2. The author's name is pronounced via a shipped built-in dictionary
///      entry, and a user's own entry for any word still wins.
@Suite struct NarrationPronunciationTests {

    // MARK: - Never-silent (end-to-end, real bundled lexicon)

    @Test func authorNameProducesRealTokensNotSilence() throws {
        // "Fakkeldy" is not in the lexicon. The phoneme string must carry no
        // dropped `❓`, and must map to at least one REAL Kokoro token (not just
        // the boundary 0 / space 16 ids that would render as a silent gap).
        let phonemes = KokoroG2P().phonemes(for: "by Dan Fakkeldy")
        #expect(!phonemes.isEmpty)
        #expect(!phonemes.contains("❓"))

        let ids = try KokoroPhonemeVocab().ids(forPhonemes: phonemes)
        #expect(ids.contains { $0 != 0 && $0 != 16 })
    }

    // MARK: - Built-in pronunciation dictionary

    @Test func builtInDefaultPronouncesAuthorName() {
        // With no user entries, the built-in default still wraps the surname in
        // Misaki link syntax so it is pronounced exactly (not approximated).
        let out = PronunciationOverrides.withBuiltInDefaults([:]).apply(to: "by Dan Fakkeldy")
        #expect(out.contains("[Fakkeldy](/fˈækəldi/)"))
    }

    @Test func builtInDefaultPronouncesCampbellsSoup() {
        let out = PronunciationOverrides.withBuiltInDefaults([:]).apply(to: "Campbell's soup")
        #expect(out.contains("[Campbell](/kˈæmbəl/)'s soup"))
    }

    @Test func builtInDefaultsCoverReportedKokoroMispronunciations() {
        let out = PronunciationOverrides.withBuiltInDefaults([:]).apply(
            to: "Xcode fixed the timeframe and re-rendered the chapter.")

        #expect(out.contains("[Xcode](/ˈɛks kˈOd/)"))
        #expect(out.contains("[timeframe](/tˈImfɹˌAm/)"))
        #expect(out.contains("[re](/ɹi/)-rendered"))
    }

    @Test func builtInReDefaultDoesNotRewriteCommonReWords() {
        let out = PronunciationOverrides.withBuiltInDefaults([:]).apply(
            to: "review the return record before restart.")

        #expect(!out.contains("[review]"))
        #expect(!out.contains("[return]"))
        #expect(!out.contains("[record]"))
        #expect(!out.contains("[restart]"))
    }

    @Test func builtInReDefaultDoesNotRewriteContractions() {
        let out = PronunciationOverrides.withBuiltInDefaults([:]).apply(
            to: "you're sure we're ready and they’re calm.")

        #expect(!out.contains("[re](/ɹi/)'"))
        #expect(out.contains("you're"))
        #expect(out.contains("we're"))
        #expect(out.contains("they’re"))
    }

    @Test func builtInDefaultReachesG2PAsExactPhonemes() {
        // End-to-end: the built-in entry flows through `apply` → Misaki link
        // parsing → the exact override phonemes appear in the G2P output.
        let text = PronunciationOverrides.withBuiltInDefaults([:]).apply(to: "by Dan Fakkeldy")
        let phonemes = KokoroG2P().phonemes(for: text)
        #expect(phonemes.contains("fˈækəldi"))
    }

    @Test func reportedKokoroMispronunciationsReachG2PAsExactPhonemes() {
        let text = PronunciationOverrides.withBuiltInDefaults([:]).apply(
            to: "Xcode fixed the timeframe and re-rendered the chapter.")
        let phonemes = KokoroG2P().phonemes(for: text)

        #expect(phonemes.contains("ˈɛks kˈOd"))
        #expect(phonemes.contains("tˈImfɹˌAm"))
        #expect(phonemes.contains("ɹi ɹˈɛndəɹd"))
    }

    @Test func userEntryOverridesBuiltInDefault() {
        // A user's own pronunciation for the same word must win over the built-in.
        let out =
            PronunciationOverrides
            .withBuiltInDefaults(["Fakkeldy": "fˈuːtɛst"])
            .apply(to: "Fakkeldy")
        #expect(out.contains("fˈuːtɛst"))
        #expect(!out.contains("fˈækəldi"))
    }

    @Test func userEntryOverridesBuiltInCaseInsensitively() {
        // A lowercase user entry must replace the capitalized built-in — not
        // coexist with it (which would make `apply` pick one ambiguously).
        let merged = PronunciationOverrides.withBuiltInDefaults(["fakkeldy": "fˈuːtɛst"])
        let fakkeldyKeys = merged.entries.keys.filter { $0.lowercased() == "fakkeldy" }
        #expect(fakkeldyKeys.count == 1)
        #expect(merged.apply(to: "Fakkeldy").contains("fˈuːtɛst"))
    }

    @MainActor
    @Test func storeOverridesIncludeBuiltInDefaults() {
        // The map NarrationService applies (via the store) carries the built-ins
        // even when the user has added nothing.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = PronunciationOverrideStore(directory: tmp)
        #expect(store.overrides().entries["Fakkeldy"] == "fˈækəldi")
    }

    // MARK: - Per-book override closure (M4)

    @MainActor
    @Test func perBookOverrideClosureRewritesBookSpecificWord() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let store = PronunciationOverrideStore(directory: tmp)
        let bookID = "file:///Books/Dune/"
        try store.set(word: "Arrakis", ipa: "ɑˈɹɑːkɪs", forBookID: bookID)

        // The render call sites build exactly this closure (with `.shared`); here we
        // bind a test store to prove the per-book id threads into `apply`.
        let overridesClosure: () -> PronunciationOverrides = { store.overrides(forBookID: bookID) }
        let rewritten = overridesClosure().apply(to: "The sands of Arrakis are endless.")
        #expect(rewritten == "The sands of [Arrakis](/ɑˈɹɑːkɪs/) are endless.")

        // A book without the entry leaves the word untouched.
        let bare = store.overrides(forBookID: "file:///Books/Empty/")
            .apply(to: "The sands of Arrakis are endless.")
        #expect(bare == "The sands of Arrakis are endless.")
    }
}
