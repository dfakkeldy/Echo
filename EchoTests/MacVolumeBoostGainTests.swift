// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// Unit tests for the pure dB→linear gain conversion used by the macOS volume
/// boost. The MTAudioProcessingTap wiring itself lives in the `Echo macOS`
/// target (verified structurally in G4); only the math is unit-tested here.
struct MacVolumeBoostGainTests {

    @Test func disabledIsUnityGain() {
        #expect(MacVolumeBoost.linearGain(enabled: false, gainDB: 9.0) == 1.0)
    }

    @Test func zeroDBIsUnityGain() {
        let g = MacVolumeBoost.linearGain(enabled: true, gainDB: 0.0)
        #expect(abs(g - 1.0) < 0.0001)
    }

    @Test func sixDBIsRoughlyDouble() {
        let g = MacVolumeBoost.linearGain(enabled: true, gainDB: 6.0)
        #expect(abs(g - 1.995262) < 0.001)
    }

    @Test func nineDBMatchesIOSDefault() {
        let g = MacVolumeBoost.linearGain(enabled: true, gainDB: 9.0)
        #expect(abs(g - 2.818383) < 0.001)
    }

    @Test func negativeGainAttenuates() {
        let g = MacVolumeBoost.linearGain(enabled: true, gainDB: -6.0)
        #expect(g < 1.0 && g > 0.0)
    }
}
