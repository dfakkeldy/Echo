import Foundation

/// A soundscape preset for ambient background audio.
struct SoundscapePreset: Identifiable, Sendable {
    let id: String
    let name: String
    let sfSymbol: String
    let category: Category
    /// Name of a bundled audio file (without extension), or nil for generative-only presets.
    let fileName: String?
    /// Configuration for generative audio (noise, binaural beats, etc.), or nil for file-based presets.
    let generatorConfig: GeneratorConfig?

    enum Category: String, Sendable {
        case nature
        case urban
        case tonal
    }

    /// Configuration for a generative (procedural) sound source.
    struct GeneratorConfig: Sendable {
        let type: GeneratorType
        /// Carrier frequency in Hz (used by binaural beats and isochronic tones).
        let carrierFrequency: Double?
        /// Beat frequency in Hz (used by binaural beats only).
        let beatFrequency: Double?
        /// Pulse rate in Hz (used by isochronic tones only).
        let pulseRate: Double?

        enum GeneratorType: String, Sendable {
            case whiteNoise
            case pinkNoise
            case brownNoise
            case binauralBeats
            case isochronic
        }
    }
}
