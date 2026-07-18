// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Shared math for the watch Digital Crown volume control.
///
/// The crown adjusts Echo's app-level output gain in decibels (not the system
/// volume), so both sides of the WatchConnectivity link must agree on the gain
/// range and the delta-to-dB mapping: the iPhone (`WatchCommandRouter`) applies
/// deltas authoritatively, while the watch mirrors the same formula for an
/// optimistic local indicator and step-crossing haptics.
nonisolated enum WatchCrownVolume {
    /// Inclusive gain range in dB applied to the audio engine.
    static let minGainDB: Double = -40
    static let maxGainDB: Double = 9

    /// dB change per 1.0 of crown rotation delta at sensitivity 1.0.
    static let gainPerRotationUnit: Double = 6

    /// Mirrors `SettingsManager.Defaults.crownVolumeSensitivity` for use on the
    /// watch before the phone has synced a value.
    static let defaultSensitivity: Double = 0.05

    /// Number of discrete haptic steps across the full gain range. Matches the
    /// 16-step system volume convention so a `.click` fires only when the level
    /// moves by an audibly meaningful amount (~3 dB).
    static let hapticStepCount = 16

    /// Applies a crown rotation delta to a gain value, clamped to the range.
    /// Identical to the authoritative iPhone-side computation.
    static func applying(delta: Double, sensitivity: Double, to gainDB: Double) -> Double {
        let effectiveSensitivity = sensitivity > 0 ? sensitivity : defaultSensitivity
        let raw = gainDB + delta * gainPerRotationUnit * effectiveSensitivity
        return min(maxGainDB, max(minGainDB, raw))
    }

    /// Normalizes a gain to 0...1 for indicator rendering.
    static func fraction(forGainDB gainDB: Double) -> Double {
        let span = maxGainDB - minGainDB
        guard span > 0 else { return 0 }
        return min(1, max(0, (gainDB - minGainDB) / span))
    }

    /// The indicator position of the neutral 0 dB gain, used to draw a notch.
    static var neutralFraction: Double { fraction(forGainDB: 0) }

    /// Discrete step index (0...hapticStepCount) for haptic threshold detection.
    /// A haptic should fire only when this index changes between two gains.
    static func stepIndex(forGainDB gainDB: Double) -> Int {
        let idx = Int((fraction(forGainDB: gainDB) * Double(hapticStepCount)).rounded(.down))
        return min(hapticStepCount, max(0, idx))
    }

    /// Whether moving from `oldGainDB` to `newGainDB` crosses a haptic step
    /// boundary (including landing on the min/max rail for the first time).
    static func crossesHapticStep(from oldGainDB: Double, to newGainDB: Double) -> Bool {
        guard oldGainDB != newGainDB else { return false }
        if stepIndex(forGainDB: oldGainDB) != stepIndex(forGainDB: newGainDB) { return true }
        // Landing on a rail is a threshold even when it falls inside the last step.
        let hitMin = newGainDB <= minGainDB && oldGainDB > minGainDB
        let hitMax = newGainDB >= maxGainDB && oldGainDB < maxGainDB
        return hitMin || hitMax
    }
}
