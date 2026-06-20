// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS) || os(macOS)
    import Foundation
    import Testing

    @testable import Echo

    /// `KokoroFrontEnd` caches the immutable Kokoro front-half (G2P + vocab +
    /// per-voice style packs) so they load once instead of per sub-chunk. These
    /// tests pin the two guarantees that make that caching safe: it is
    /// behavior-preserving (same `(ids, refS)` as constructing the three objects
    /// inline), and it memoizes the voice pack per voice id.
    @Suite struct KokoroFrontEndTests {

        private let voice = VoiceID("af_heart")

        @Test func encodeMatchesInlineConstruction() throws {
            let text = "Once upon a time, there was a test."
            let frontEnd = KokoroFrontEnd()
            let got = try frontEnd.encode(text: text, voice: voice)

            // Reference: exactly what OnnxKokoroEngine.synthesize did inline before
            // the cache was introduced.
            let g2p = KokoroG2P()
            let vocab = try KokoroPhonemeVocab()
            let pack = try KokoroVoicePack(named: voice.rawValue)
            let phonemes = g2p.phonemes(for: text)
            let expectedIDs = vocab.ids(forPhonemes: phonemes)
            let expectedRefS = pack.refS(forPhonemeCount: phonemes.count)

            #expect(got.ids == expectedIDs)
            #expect(got.refS == expectedRefS)
            #expect(got.refS.count == KokoroVoicePack.embeddingDim)
        }

        @Test func repeatedEncodeIsDeterministic() throws {
            let frontEnd = KokoroFrontEnd()
            let first = try frontEnd.encode(text: "Hello there.", voice: voice)
            let second = try frontEnd.encode(text: "Hello there.", voice: voice)
            #expect(first.ids == second.ids)
            #expect(first.refS == second.refS)
        }

        @Test func voicePackIsMemoizedPerVoice() throws {
            let frontEnd = KokoroFrontEnd()
            _ = try frontEnd.encode(text: "a", voice: voice)
            _ = try frontEnd.encode(text: "b", voice: voice)
            // Two encodes for the same voice load exactly one pack.
            #expect(frontEnd.cachedVoices == [voice.rawValue])
        }
    }
#endif
