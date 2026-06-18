// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import Echo

@Suite struct KokoroG2PTests {

    @Test func producesNonEmptyPhonemesForEnglish() {
        let p = KokoroG2P().phonemes(for: "Hello world.")
        #expect(!p.isEmpty)
        // Word boundary is preserved (the vocab maps " " → 16).
        #expect(p.contains(" "))
    }

    @Test func phonemizesDeterministically() {
        // Same input → same output across instances (no RNG-dependent path).
        let a = KokoroG2P().phonemes(for: "The quick brown fox.")
        let b = KokoroG2P().phonemes(for: "The quick brown fox.")
        #expect(a == b)
    }
}
