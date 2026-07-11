// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct KokoroPhonemeVocabTests {

    @Test func loadsBundledVocab() throws {
        let v = try KokoroPhonemeVocab()
        // The Kokoro-82M token id space is 0…177 inclusive (178 ids), with
        // BOS/EOS = 0 and gaps in 1…177. `tokenCount` reports the id space,
        // not the number of mapped characters (which is 114).
        #expect(v.tokenCount == 178)
    }

    @Test func legacyMappingCanStillDropUnknownCharacters() throws {
        let vocab = try KokoroPhonemeVocab()
        #expect(vocab.ids(forPhonemes: " .\u{0000}") == [0, 16, 4, 0])
    }

    @Test func plannedMappingRejectsUnknownCharacters() throws {
        let vocab = try KokoroPhonemeVocab()
        #expect(throws: KokoroPhonemeVocab.EncodingError.unsupportedCharacters("\u{0000}")) {
            try vocab.validatedIDs(forPhonemes: "hɛ\u{0000}loʊ")
        }
    }

    @Test func wrapsEmptyStringInBosEosOnly() throws {
        let v = try KokoroPhonemeVocab()
        #expect(v.ids(forPhonemes: "") == [0, 0])
    }

    @Test func allMappedCharsRoundTrip() throws {
        // Every character the G2P can emit is either mapped or dropped — never
        // an out-of-range id (Phase 0.1 vocab-parity gate).
        let v = try KokoroPhonemeVocab()
        let ids = v.ids(forPhonemes: "hɛˈloʊ wɜ˞ld")  // "hello world"-ish IPA
        #expect(ids.allSatisfy { $0 >= 0 && $0 < Int32(v.tokenCount) })
        #expect(ids.first == 0 && ids.last == 0)
    }

    @Test func oovWordProducesRealTokensNotSilence() throws {
        // End-to-end regression for the "Jacqui = silence" bug: the OOV fallback
        // must yield phonemes that map to at least one REAL token — not just the
        // boundary (0) and space (16) ids that render as a silent gap.
        let phonemes = KokoroG2P().phonemes(for: "Jacqui")
        let ids = try KokoroPhonemeVocab().ids(forPhonemes: phonemes)
        #expect(ids.contains { $0 != 0 && $0 != 16 })
    }
}
