// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct LexiconOnlyG2PTests {

    @Test func lexiconWordPhonemizes() {
        // "hello" is in the gold lexicon.
        let p = KokoroG2P().phonemes(for: "hello")
        #expect(!p.isEmpty)
        #expect(!p.contains("❓"))  // no OOV marker on a known word
    }

    @Test func oovProperNounIsPronouncedNotSilent() {
        // The reported bug: an OOV name like "Jacqui" used to emit the ❓ unk
        // marker, which KokoroPhonemeVocab drops → silence. It must now be voiced
        // by the grapheme→IPA fallback (≈ ʤˈækɪ): non-empty, no ❓, and it must
        // contain the "J" affricate ʤ to prove it is actually pronounced.
        let p = KokoroG2P().phonemes(for: "Jacqui")
        #expect(!p.isEmpty)
        #expect(!p.contains("❓"))
        #expect(p.contains("ʤ"))
    }

    @Test func inventedWordIsPronouncedNotSilent() {
        // A made-up token in no lexicon must still produce vocab-safe phonemes,
        // never the dropped ❓.
        let p = KokoroG2P().phonemes(for: "Xyzqwf")
        #expect(!p.isEmpty)
        #expect(!p.contains("❓"))
    }

    @Test func mixedLexiconAndOovDoesNotCrash() {
        // Real prose mixes known + unknown words; the whole string must return.
        let p = KokoroG2P().phonemes(for: "The Xyzqwf server restarted.")
        #expect(!p.isEmpty)
    }
}
