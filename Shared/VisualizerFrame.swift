import Foundation

struct VisualizerFrame: Sendable {
    let rms: Float
    let peak: Float
    let spectrum: [Float]
    let timestamp: TimeInterval
}
