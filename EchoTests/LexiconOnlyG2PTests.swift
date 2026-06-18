// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import Echo

@Suite struct LexiconOnlyG2PTests {

    @Test func lexiconWordPhonemizes() {
        // "hello" is in the gold lexicon.
        let p = KokoroG2P().phonemes(for: "hello")
        #expect(!p.isEmpty)
        #expect(!p.contains("❓")) // no OOV marker on a known word
    }

    @Test func oovWordDegradesGracefullyDoesNotCrash() {
        // An invented proper noun that's in no lexicon and (now) has no BART
        // fallback. It must not crash; it emits the ❓ unk marker.
        let p = KokoroG2P().phonemes(for: "Xyzqwf")
        // The unk glyph appears somewhere in the output (the word slot).
        #expect(p.contains("❓"))
    }

    @Test func mixedLexiconAndOovDoesNotCrash() {
        // Real prose mixes known + unknown words; the whole string must return.
        let p = KokoroG2P().phonemes(for: "The Xyzqwf server restarted.")
        #expect(!p.isEmpty)
    }
}
