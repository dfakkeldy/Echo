// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// BART OOV-fallback stub. The real neural network (in the other files of this
/// directory, backed by mlx-swift) was removed from Echo to drop the MLX
/// dependency — mlx-swift 0.30.2 has an upstream iOS-Simulator link bug
/// (ml-explore/mlx-swift#341) that blocked the whole sim test suite, and the
/// BART fallback's value on Echo's nonfiction workload is low (it guesses at
/// proper nouns/brands the user can override instead — see
/// PronunciationOverrides).
///
/// This stub keeps the type + `callAsFunction` seam so `EnglishG2P` compiles
/// unchanged. An OOV word returns the `unk` glyph ("❓"), which
/// `KokoroPhonemeVocab` drops → the word is silent. The PronunciationOverrides
/// feature is the supported way to give OOV words a real pronunciation.
final class EnglishFallbackNetwork {
  private let unk: String

  init(british: Bool, unk: String = "❓") {
    self.unk = unk
  }

  func callAsFunction(_ word: MToken) -> (phoneme: String, rating: Int) {
    (unk, 1)
  }
}
