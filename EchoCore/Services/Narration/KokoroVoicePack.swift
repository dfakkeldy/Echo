// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Loads a Kokoro voice style pack (the `af_heart` "Ava" voice) and selects the
/// `[256]` style row a given utterance should use.
///
/// The Hub `voices/af_heart.bin` is a flat little-endian Float32 blob reshaped
/// to `[N, 256]` (N = 510 = Kokoro's `MAX_PHONEME_LENGTH`). Row index is
/// `len(phonemes) - 1`, clamped to `[0, N-1]` — mirroring the Python reference
/// `voice_embedding_for_phoneme_string` (`kokoro/pipeline.py:131`):
///
/// ```python
/// idx = len(phonemes) - 1
/// idx = max(0, min(idx, pack.shape[0] - 1))
/// return pack[idx]
/// ```
///
/// A 1-D `(256,)` pack is returned as-is (the `pack.dim() == 1` branch).
///
/// Source: `hexgrad/Kokoro-82M` → `voices/af_heart.bin` (Apache-2.0), converted
/// verbatim to `EchoCore/Resources/af_heart.f32`. The row count lives in a
/// sidecar `af_heart.rows` text file so the loader is self-describing.
/// sha256(af_heart.f32) = d583ccff3cdca2f7fae535cb998ac07e9fcb90f09737b9a41fa2734ec44a8f0b
nonisolated struct KokoroVoicePack {
    static let embeddingDim = 256

    private let values: [Float]
    let rows: Int

    /// Loads `<name>.f32` (+ `<name>.rows`) from the app bundle.
    init(named name: String) throws {
        guard
            let f32URL = NarrationResources.url(forResource: name, withExtension: "f32"),
            let rowsURL = NarrationResources.url(forResource: name, withExtension: "rows")
        else {
            throw NarrationError.modelDownloadFailed(name: name, underlying: nil)
        }
        let data = try Data(contentsOf: f32URL)
        let rowCountText = try String(contentsOf: rowsURL, encoding: .utf8)
        guard let rowCount = Int(rowCountText.trimmingCharacters(in: .whitespacesAndNewlines))
        else {
            throw NarrationError.modelDownloadFailed(name: "\(name).rows", underlying: nil)
        }
        // Reinterpret raw little-endian Float32 bytes as [Float]. iOS/macOS are
        // little-endian, so no endianness swap is needed on the target platforms.
        let count = data.count / MemoryLayout<Float>.size
        guard count == rowCount * Self.embeddingDim else {
            throw NarrationError.modelDownloadFailed(name: name, underlying: nil)
        }
        self.values = data.withUnsafeBytes { rawBuffer -> [Float] in
            let pointer = rawBuffer.bindMemory(to: Float.self)
            return Array(pointer)
        }
        self.rows = rowCount
    }

    /// The `[256]` style row for an utterance with `phonemeCount` phonemes.
    /// Index = `max(0, min(phonemeCount - 1, rows - 1))`. A 1-row pack returns
    /// itself regardless of count.
    func refS(forPhonemeCount phonemeCount: Int) -> [Float] {
        if rows == 1 { return values }
        let idx = max(0, min(phonemeCount - 1, rows - 1))
        let start = idx * Self.embeddingDim
        return Array(values[start..<(start + Self.embeddingDim)])
    }
}
