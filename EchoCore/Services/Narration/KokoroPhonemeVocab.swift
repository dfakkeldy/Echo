// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Maps a MisakiSwift IPA phoneme string to the Kokoro-82M `[Int32]` token ids
/// that `KokoroPipeline.synthesize` consumes.
///
/// Mirrors the Python reference `[0, *map(vocab.get, phonemes), 0]`:
/// - BOS (id 0) wraps the front, EOS (id 0) wraps the back.
/// - Each character is looked up in the bundled `_kokoro_vocab.json`; an
///   unmapped character is silently dropped (Phase 0.1 proved Misaki's emitted
///   charset ⊆ the vocab, so drops only hit truly-unphonemizable tokens like
///   the `❓` OOV marker — rare and acceptable).
///
/// The vocab's id space is 0…177 inclusive (178 ids), though only 114
/// characters are mapped (1…177 has gaps). `tokenCount` reports the id space so
/// callers can range-check ids.
struct KokoroPhonemeVocab {
    /// BOS / EOS token id (the Kokoro vocab's pad/boundary token).
    static let boundaryTokenId: Int32 = 0

    private let charToId: [Character: Int32]
    private let idSpaceSize: Int

    /// Loads the bundled `_kokoro_vocab.json` (`{"vocab": {char: id}}`).
    init() throws {
        guard
            let url = NarrationResources.url(
                forResource: "_kokoro_vocab", withExtension: "json")
        else {
            throw NarrationError.modelDownloadFailed(
                name: "_kokoro_vocab.json", underlying: nil)
        }
        let data = try Data(contentsOf: url)
        let root = try JSONDecoder().decode(VocabFile.self, from: data)
        var map: [Character: Int32] = [:]
        var maxId: Int32 = 0
        for (string, id) in root.vocab {
            // Each vocab key is a single character; guard against malformed entries.
            guard let char = string.first else { continue }
            map[char] = id
            if id > maxId { maxId = id }
        }
        self.charToId = map
        // Id space is 0…maxId inclusive (+1 for the 0 token).
        self.idSpaceSize = Int(maxId) + 1
    }

    /// The size of the Kokoro id space (178 for the bundled vocab). Useful for
    /// range-checking synthesized ids.
    var tokenCount: Int { idSpaceSize }

    /// `[BOS] + (each mapped character) + [EOS]`. Unmapped characters drop.
    func ids(forPhonemes phonemes: String) -> [Int32] {
        var ids: [Int32] = [Self.boundaryTokenId]
        ids.reserveCapacity(phonemes.count + 2)
        for char in phonemes {
            if let id = charToId[char] {
                ids.append(id)
            }
        }
        ids.append(Self.boundaryTokenId)
        return ids
    }

    private struct VocabFile: Decodable {
        let vocab: [String: Int32]
    }
}
