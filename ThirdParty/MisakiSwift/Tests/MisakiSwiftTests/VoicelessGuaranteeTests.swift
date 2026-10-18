import Testing

@testable import MisakiSwift

/// The never-voiceless guarantee: no letter-bearing word may ever reach the
/// phoneme vocab as a dropped `❓` (which renders as silence). Historically an
/// OOV word like a surname could be silently skipped; these lock in that any
/// word the lexicon + OOV fallback leave unvoiced is spelled out via the
/// deterministic grapheme→IPA approximator instead.
@Suite struct VoicelessGuaranteeTests {
    private let g2p = EnglishG2P(british: false)

    @Test func rescuesNilPhonemeForLetterWord() {
        // A letter-bearing token left `nil` must be approximated, never skipped.
        let out = g2p.voicedPhonemes(text: "Fakkeldy", current: nil)
        #expect(!out.isEmpty)
        #expect(!out.contains("❓"))
    }

    @Test func rescuesUnkMarkerForLetterWord() {
        // The legacy `❓` unk marker (which the Kokoro vocab drops) must be
        // replaced with real, speakable phonemes.
        let out = g2p.voicedPhonemes(text: "Fakkeldy", current: "❓")
        #expect(!out.isEmpty)
        #expect(!out.contains("❓"))
    }

    @Test func keepsGoodPhonemesUnchanged() {
        // A word that already has real phonemes must pass through untouched.
        let out = g2p.voicedPhonemes(text: "hello", current: "hˈɛloʊ")
        #expect(out == "hˈɛloʊ")
    }

    @Test func doesNotInventPhonemesForPunctuation() {
        // A token with no letters (punctuation/whitespace) must NOT be forced
        // to speak — it legitimately contributes nothing.
        let out = g2p.voicedPhonemes(text: ",", current: nil)
        #expect(out.isEmpty)
    }

    @Test func foldsDiacriticsWhenRescuing() {
        // Accented OOV words must still be voiced (and vocab-safe).
        let out = g2p.voicedPhonemes(text: "café", current: "❓")
        #expect(!out.isEmpty)
        #expect(!out.contains("❓"))
    }

    @Test func fullPipelineNeverEmitsUnkForOOVName() {
        // End-to-end (empty lexicon under `swift test`, so every word is OOV):
        // the assembled phoneme string must contain no dropped unk marker.
        let (ph, _) = g2p.phonemize(text: "by Dan Fakkeldy")
        #expect(!ph.isEmpty)
        #expect(!ph.contains("❓"))
    }
}
