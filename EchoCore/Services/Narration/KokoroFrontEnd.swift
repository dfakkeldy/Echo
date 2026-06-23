// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS) || os(macOS)
    import Foundation

    /// Caches the immutable Kokoro "front half" — the MisakiSwift G2P engine, the
    /// phoneme vocab, and per-voice style packs — so they load ONCE and are reused
    /// across every `synthesize` call.
    ///
    /// Why this exists: `OnnxKokoroEngine.synthesize` previously rebuilt all three on
    /// every call, and `NarrationService` calls `synthesize` once per text sub-chunk
    /// — dozens to hundreds of times per chapter. Each rebuild re-parsed
    /// ~6 MB of MisakiSwift lexicon JSON (`us_gold.json` + `us_silver.json`, each
    /// run through `growDictionary`) and re-read the 510×256 voice blob, of which
    /// only one 256-float row is used. That was pure per-sub-chunk CPU + allocator
    /// churn proportional to book length.
    ///
    /// Caching is behavior-preserving: the G2P engine and vocab depend only on the
    /// input text (not on render state), and a voice pack depends only on its voice
    /// id, so the same `(text, voice)` always yields the same `(ids, refS)`. Held on
    /// the `OnnxKokoroEngine` actor, so every access is actor-isolated — no Sendable
    /// concern despite the mutable cache.
    final class KokoroFrontEnd {
        private var g2p: KokoroG2P?
        private var vocab: KokoroPhonemeVocab?
        private var voicePacks: [String: KokoroVoicePack] = [:]

        init() {}

        /// Voice ids whose style pack has been loaded and cached. Test seam for the
        /// memoization guarantee; also lets a caller see which voices are warm.
        var cachedVoices: [String] { Array(voicePacks.keys) }

        /// Encodes `text` for `voice` into the Kokoro model inputs: the BOS/EOS
        /// wrapped `[Int32]` token ids and the 256-dim style row. Each front-half
        /// component is built on first use and reused thereafter.
        func encode(text: String, voice: VoiceID) throws -> (ids: [Int32], refS: [Float]) {
            let g2p = g2p(for: text)
            let vocab = try phonemeVocab()
            let pack = try voicePack(named: voice.rawValue)

            let phonemes = g2p.phonemes(for: text)
            let ids = vocab.ids(forPhonemes: phonemes)
            let refS = pack.refS(forPhonemeCount: phonemes.count)
            return (ids, refS)
        }

        // MARK: - Cached components

        private func g2p(for _: String) -> KokoroG2P {
            if let g2p { return g2p }
            let built = KokoroG2P()
            g2p = built
            return built
        }

        private func phonemeVocab() throws -> KokoroPhonemeVocab {
            if let vocab { return vocab }
            let built = try KokoroPhonemeVocab()
            vocab = built
            return built
        }

        private func voicePack(named name: String) throws -> KokoroVoicePack {
            if let cached = voicePacks[name] { return cached }
            let built = try KokoroVoicePack(named: name)
            voicePacks[name] = built
            return built
        }
    }
#endif
