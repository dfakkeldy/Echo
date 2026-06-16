import Foundation

/// Stateful 2nd-order Butterworth low-pass for rendered narration. Tames the
/// Kokoro A14 vocoder's high-frequency artifact — the audible "whine" whose
/// energy abnormally *exceeds* the 6–9 kHz band above 9 kHz (confirmed by
/// on-device spectral analysis). Mirrors the ffmpeg `lowpass=f=8500:poles=2`
/// that the owner preferred in an A/B.
///
/// Applied to each synthesized sub-chunk's samples *before* they're written, with
/// the biquad state carried across a chapter's sub-chunks so there is no
/// discontinuity (click) at chunk boundaries. Pure + deterministic → unit-testable
/// without the TTS engine. Coefficients are the RBJ cookbook low-pass, computed
/// from the cutoff so the cutoff stays a single tunable knob.
struct NarrationLowPass {
    // a0-normalised biquad coefficients (difference equation:
    // y[n] = b0·x[n] + b1·x[n-1] + b2·x[n-2] − a1·y[n-1] − a2·y[n-2]).
    private let b0: Float
    private let b1: Float
    private let b2: Float
    private let a1: Float
    private let a2: Float

    // Filter state (per channel; narration is mono).
    private var x1: Float = 0
    private var x2: Float = 0
    private var y1: Float = 0
    private var y2: Float = 0

    /// - Parameters:
    ///   - cutoffHz: −3 dB corner. 8500 Hz matches the owner-preferred A/B.
    ///   - sampleRate: Kokoro output rate (24 kHz).
    init(cutoffHz: Double = 8500, sampleRate: Double = 24_000) {
        let w0 = 2.0 * Double.pi * cutoffHz / sampleRate
        let cosW = cos(w0)
        let sinW = sin(w0)
        let alpha = sinW / (2.0 * 0.7071067811865476)  // Butterworth Q = 1/√2
        let a0 = 1.0 + alpha
        b0 = Float((1.0 - cosW) / 2.0 / a0)
        b1 = Float((1.0 - cosW) / a0)
        b2 = Float((1.0 - cosW) / 2.0 / a0)
        a1 = Float(-2.0 * cosW / a0)
        a2 = Float((1.0 - alpha) / a0)
    }

    /// Filter `samples`, advancing the filter state so the next call continues
    /// seamlessly. Returns a new array (input is left untouched).
    mutating func process(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else { return samples }
        var out = [Float](repeating: 0, count: samples.count)
        for i in samples.indices {
            let x = samples[i]
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1
            x1 = x
            y2 = y1
            y1 = y
            out[i] = y
        }
        return out
    }
}
