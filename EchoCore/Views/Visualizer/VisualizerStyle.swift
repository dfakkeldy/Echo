// SPDX-License-Identifier: GPL-3.0-or-later
// MARK: - VisualizerStyle

/// Defines the four Metal-based audio visualizer styles available in Echo.
/// Each case maps to a fragment shader in `VisualizerShaders.metal`.
enum VisualizerStyle: String, CaseIterable {
    case acidWarp = "Acid Warp"
    case waveformRiver = "Waveform River"
    case particleFlow = "Particle Flow"
    case spectrumBars = "Spectrum Bars"

    var sfSymbol: String {
        switch self {
        case .acidWarp: "sparkles"
        case .waveformRiver: "waveform"
        case .particleFlow: "circle.dotted"
        case .spectrumBars: "chart.bar"
        }
    }
}
