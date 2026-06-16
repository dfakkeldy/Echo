// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// An audio analysis frame produced by `VisualizerDataProviding` at ~30 fps.
///
/// Contains RMS amplitude, peak amplitude, a 16-bin power spectrum,
/// and a timestamp suitable for driving audio-reactive visualizers.
struct VisualizerFrame: Sendable {
    /// Root-mean-square amplitude (0…1 range after normalization).
    let rms: Float

    /// Peak sample amplitude (0…1 range after normalization).
    let peak: Float

    /// 16-bin power spectrum in dBFS-normalised values.
    let spectrum: [Float]

    /// `CACurrentMediaTime()` at which this frame was captured.
    let timestamp: TimeInterval
}
