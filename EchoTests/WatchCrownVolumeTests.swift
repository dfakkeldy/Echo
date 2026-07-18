// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct WatchCrownVolumeTests {

    // MARK: - Delta application

    @Test("delta math matches the authoritative iPhone-side formula")
    func deltaMatchesRouterFormula() {
        // gain + delta * 6 * sensitivity, the historical WatchCommandRouter math.
        let result = WatchCrownVolume.applying(delta: 1.0, sensitivity: 0.05, to: 0)
        #expect(abs(result - 0.3) < 0.0001)
    }

    @Test("gain clamps to the -40...+9 dB range")
    func gainClamps() {
        let high = WatchCrownVolume.applying(delta: 100, sensitivity: 1.0, to: 8)
        let low = WatchCrownVolume.applying(delta: -100, sensitivity: 1.0, to: -39)
        #expect(high == WatchCrownVolume.maxGainDB)
        #expect(low == WatchCrownVolume.minGainDB)
    }

    @Test("non-positive sensitivity falls back to the shared default")
    func sensitivityFallback() {
        let withZero = WatchCrownVolume.applying(delta: 1.0, sensitivity: 0, to: 0)
        let withDefault = WatchCrownVolume.applying(
            delta: 1.0, sensitivity: WatchCrownVolume.defaultSensitivity, to: 0)
        #expect(withZero == withDefault)
    }

    // MARK: - Indicator fraction

    @Test("fraction maps the gain range monotonically onto 0...1")
    func fractionMapping() {
        #expect(WatchCrownVolume.fraction(forGainDB: WatchCrownVolume.minGainDB) == 0)
        #expect(WatchCrownVolume.fraction(forGainDB: WatchCrownVolume.maxGainDB) == 1)
        let mid = WatchCrownVolume.fraction(forGainDB: -15.5)
        #expect(abs(mid - 0.5) < 0.0001)
        // Values outside the range clamp instead of overflowing the bar.
        #expect(WatchCrownVolume.fraction(forGainDB: -100) == 0)
        #expect(WatchCrownVolume.fraction(forGainDB: 100) == 1)
    }

    @Test("neutral fraction marks 0 dB inside the range")
    func neutralFraction() {
        let neutral = WatchCrownVolume.neutralFraction
        #expect(neutral > 0 && neutral < 1)
        #expect(abs(neutral - (40.0 / 49.0)) < 0.0001)
    }

    // MARK: - Haptic steps

    @Test("tiny deltas inside one step do not cross a haptic threshold")
    func tinyDeltaNoStep() {
        // One default-sensitivity crown tick is 0.003 dB; a step is ~3 dB.
        let old = -20.0
        let new = WatchCrownVolume.applying(delta: 0.01, sensitivity: 0.05, to: old)
        #expect(WatchCrownVolume.crossesHapticStep(from: old, to: new) == false)
    }

    @Test("crossing a step boundary triggers exactly at the boundary")
    func stepBoundaryCrossing() {
        let stepSpan =
            (WatchCrownVolume.maxGainDB - WatchCrownVolume.minGainDB)
            / Double(WatchCrownVolume.hapticStepCount)
        let justBelow = WatchCrownVolume.minGainDB + stepSpan - 0.01
        let justAbove = WatchCrownVolume.minGainDB + stepSpan + 0.01
        #expect(WatchCrownVolume.crossesHapticStep(from: justBelow, to: justAbove))
        #expect(WatchCrownVolume.crossesHapticStep(from: justAbove, to: justBelow))
    }

    @Test("landing on the min or max rail counts as a threshold")
    func railLandingIsThreshold() {
        #expect(
            WatchCrownVolume.crossesHapticStep(
                from: WatchCrownVolume.maxGainDB - 0.05, to: WatchCrownVolume.maxGainDB))
        #expect(
            WatchCrownVolume.crossesHapticStep(
                from: WatchCrownVolume.minGainDB + 0.05, to: WatchCrownVolume.minGainDB))
        // But resting on the rail stays silent.
        #expect(
            WatchCrownVolume.crossesHapticStep(
                from: WatchCrownVolume.maxGainDB, to: WatchCrownVolume.maxGainDB) == false)
    }
}
