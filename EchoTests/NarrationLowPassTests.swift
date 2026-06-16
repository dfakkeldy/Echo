import Foundation
import Testing

@testable import Echo

@Suite struct NarrationLowPassTests {

    private static let sampleRate: Double = 24_000

    private func sine(freqHz: Double, frames: Int) -> [Float] {
        (0..<frames).map { Float(sin(2.0 * Double.pi * freqHz * Double($0) / Self.sampleRate)) }
    }

    private func rms(_ samples: ArraySlice<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        let sum = samples.reduce(Float(0)) { $0 + $1 * $1 }
        return (sum / Float(samples.count)).squareRoot()
    }

    /// A 1 kHz tone passes ~unattenuated; an 11 kHz tone (near the artifact band)
    /// is strongly cut. Skip the filter's start-up transient before measuring.
    @Test func passesLowAttenuatesHigh() {
        let n = 24_000
        var lpLow = NarrationLowPass()
        var lpHigh = NarrationLowPass()
        let low = lpLow.process(sine(freqHz: 1_000, frames: n))
        let high = lpHigh.process(sine(freqHz: 11_000, frames: n))

        let lowRMS = rms(low[2_000...])
        let highRMS = rms(high[2_000...])

        // Input RMS of a full-scale sine ≈ 0.707.
        #expect(lowRMS > 0.6, "1 kHz should pass (rms \(lowRMS))")
        #expect(highRMS < 0.2, "11 kHz should be strongly attenuated (rms \(highRMS))")
        #expect(highRMS < lowRMS / 3, "high band must be well below the passband")
    }

    /// Processing in two successive calls equals processing the whole buffer at
    /// once — the state carries across calls, so a chapter's sub-chunks join
    /// seamlessly (no boundary discontinuity).
    @Test func stateCarriesAcrossCalls() {
        let whole = sine(freqHz: 3_000, frames: 4_000)
        var oneShot = NarrationLowPass()
        let a = oneShot.process(whole)

        var split = NarrationLowPass()
        let b1 = split.process(Array(whole[0..<2_000]))
        let b2 = split.process(Array(whole[2_000..<4_000]))
        let b = b1 + b2

        #expect(a.count == b.count)
        var maxDiff: Float = 0
        for i in a.indices { maxDiff = max(maxDiff, abs(a[i] - b[i])) }
        #expect(maxDiff < 1e-6, "split processing must match one-shot (diff \(maxDiff))")
    }

    @Test func emptyInputReturnsEmpty() {
        var lp = NarrationLowPass()
        #expect(lp.process([]).isEmpty)
    }
}
