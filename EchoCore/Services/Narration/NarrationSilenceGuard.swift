// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Guards against the Kokoro ONNX model occasionally returning a full-length but
/// **all-zero** waveform for a non-empty input — which lands as a stretch of pure
/// digital silence in the narrated audio (observed dropping ~10% of chunks, some
/// runs clustering 2–3 in a row into multi-second gaps). The model's own RTF logs
/// look normal because the sample *count* is right; only the *values* are zero.
///
/// Strategy, in order:
///   1. Re-run with a slightly perturbed input — a trailing space, then two. The
///      ONNX Runtime CPU EP is deterministic, so re-running the *identical* string
///      reproduces the same zero; appending whitespace changes the token ids (a
///      harmless tiny gap at the chunk tail) so an input-specific zero can recover
///      even when the fragment is too short to split.
///   2. If still silent, split the text at a word boundary and synthesize each
///      half (recovers a zero specific to a longer input string).
///   3. If a fragment is too short to split and still silent, accept it rather than
///      loop forever (bounded — better a tiny gap than a hang).
///
/// Pure and deterministic given `run`; `OnnxKokoroEngine` injects the real
/// encode-and-run closure, tests inject a stub. Empty output is treated as a
/// legitimate "nothing to say" (e.g. an all-punctuation fragment), never retried.
enum NarrationSilenceGuard {

    /// Peak-amplitude floor below which a non-empty chunk is considered silent.
    /// Real speech peaks near full scale; a bugged chunk is exact zeros — so any
    /// reasonable floor well under speech and above fp denormals separates them.
    static let defaultSilenceFloor: Float = 1e-3

    /// True when `samples` is non-empty yet effectively silent (the zero-output
    /// bug). Empty is NOT silent — it's a legitimately empty fragment.
    static func isEffectivelySilent(_ samples: [Float], floor: Float = defaultSilenceFloor) -> Bool
    {
        guard !samples.isEmpty else { return false }
        var peak: Float = 0
        for sample in samples {
            let magnitude = abs(sample)
            if magnitude > peak { peak = magnitude }
        }
        return peak < floor
    }

    /// Splits `text` at the space nearest its midpoint, for a re-synthesis retry.
    /// Returns `nil` if the text is shorter than `minLength` or has no interior
    /// space to split on (so recursion always terminates).
    static func splitForRetry(_ text: String, minLength: Int) -> (String, String)? {
        let chars = Array(text)
        guard chars.count >= minLength else { return nil }
        let mid = chars.count / 2
        var lo = mid
        var hi = mid
        while lo > 0 || hi < chars.count {
            if hi < chars.count, chars[hi] == " " {
                return (String(chars[0..<hi]), String(chars[(hi + 1)...]))
            }
            if lo > 0, chars[lo] == " " {
                return (String(chars[0..<lo]), String(chars[(lo + 1)...]))
            }
            lo -= 1
            hi += 1
        }
        return nil
    }

    /// Synthesizes `text` via `run`, guarding against silent (all-zero) output.
    /// - Parameters:
    ///   - run: synthesizes one text fragment into PCM samples (empty == nothing).
    /// - Returns: non-silent samples when recoverable; the concatenation of
    ///   re-synthesized halves; or, as a last resort, the final (possibly silent)
    ///   attempt for an unsplittable fragment.
    static func synthesize(
        _ text: String,
        floor: Float = defaultSilenceFloor,
        maxRetries: Int = 2,
        minSplitLength: Int = 16,
        run: (String) async throws -> [Float]
    ) async throws -> [Float] {
        var samples = try await run(text)
        if !isEffectivelySilent(samples, floor: floor) { return samples }

        // Perturb the input on each retry (trailing spaces) so a deterministic
        // engine doesn't just reproduce the same zero — the extra space tokens
        // are a negligible tail gap but change the model input.
        for attempt in 0..<maxRetries {
            let perturbed = text + String(repeating: " ", count: attempt + 1)
            samples = try await run(perturbed)
            if !isEffectivelySilent(samples, floor: floor) { return samples }
        }

        if let (left, right) = splitForRetry(text, minLength: minSplitLength) {
            let leftSamples = try await synthesize(
                left, floor: floor, maxRetries: maxRetries, minSplitLength: minSplitLength, run: run
            )
            let rightSamples = try await synthesize(
                right, floor: floor, maxRetries: maxRetries, minSplitLength: minSplitLength,
                run: run)
            return leftSamples + rightSamples
        }

        // Unsplittable and still silent — accept rather than loop forever.
        return samples
    }
}
