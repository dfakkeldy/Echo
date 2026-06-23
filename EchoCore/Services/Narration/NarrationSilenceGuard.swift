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

    /// Splits `text` for a re-synthesis retry, preferring a clause or sentence
    /// boundary nearest the midpoint — a space immediately following `, ; : . ! ?`
    /// — so the seam between the two separately-synthesized halves (each of which
    /// carries sentence-final prosody) lands where a pause sounds natural rather
    /// than dropped mid-clause. Falls back to the nearest plain interior space.
    ///
    /// Never splits at a space inside a pronunciation-override link `[word](/ipa/)`
    /// — a multi-word override has interior spaces — mirroring the link-awareness in
    /// `NarrationTextChunker`. Returns `nil` when the text is shorter than
    /// `minLength` or has no splittable interior space, so the recursion in
    /// `synthesize` always terminates.
    static func splitForRetry(_ text: String, minLength: Int) -> (String, String)? {
        let chars = Array(text)
        guard chars.count >= minLength else { return nil }

        // Mark every index inside a `[word](/ipa/)` link so we never split there.
        var inLink = [Bool](repeating: false, count: chars.count)
        var open = false
        for i in chars.indices {
            if chars[i] == "[" { open = true }
            inLink[i] = open
            if chars[i] == ")" { open = false }
        }

        let terminators: Set<Character> = [",", ";", ":", ".", "!", "?"]
        func splittableSpace(_ i: Int) -> Bool {
            i > 0 && i < chars.count && chars[i] == " " && !inLink[i]
        }
        func clauseSpace(_ i: Int) -> Bool {
            splittableSpace(i) && terminators.contains(chars[i - 1])
        }
        func split(at i: Int) -> (String, String) {
            (String(chars[0..<i]), String(chars[(i + 1)...]))
        }
        // The index nearest the midpoint that satisfies `accept`, searching outward.
        func nearestToMid(_ accept: (Int) -> Bool) -> Int? {
            let mid = chars.count / 2
            var lo = mid
            var hi = mid
            while lo > 0 || hi < chars.count {
                if hi < chars.count, accept(hi) { return hi }
                if lo > 0, accept(lo) { return lo }
                lo -= 1
                hi += 1
            }
            return nil
        }

        if let i = nearestToMid(clauseSpace) { return split(at: i) }
        if let i = nearestToMid(splittableSpace) { return split(at: i) }
        return nil
    }

    /// Prosody-neutral first line of silence recovery: runs `run` at each speed in
    /// `speeds` until one yields a non-silent result. A small speed change keeps the
    /// fragment as ONE utterance — unlike `splitForRetry`, which re-synthesizes the
    /// halves separately and so adds an audible mid-fragment seam — so if the model's
    /// all-zero output is specific to its `speed` input, the fragment recovers with
    /// no prosody cost. Lead `speeds` with the real playback speed (typically `1.0`)
    /// so an already-audible fragment incurs no extra synthesis.
    ///
    /// Returns the first non-silent result, or the last attempt if every speed is
    /// silent — so the caller can escalate to the text perturb/split ladder in
    /// `synthesize`. (Whether a speed nudge actually dodges the deterministic zero is
    /// a property of the real model, confirmed on device, not of this pure routing.)
    static func synthesizeWithSpeedNudge(
        speeds: [Float],
        floor: Float = defaultSilenceFloor,
        run: (Float) async throws -> [Float]
    ) async throws -> [Float] {
        var samples: [Float] = []
        for speed in speeds {
            samples = try await run(speed)
            if !isEffectivelySilent(samples, floor: floor) { return samples }
        }
        return samples
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
