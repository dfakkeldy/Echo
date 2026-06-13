import Foundation

struct SoundscapePreset: Identifiable, Equatable, Codable {
    let id: String
    let name: String
    let sfSymbol: String
    let category: Category
    let fileName: String?
    let generatorConfig: GeneratorConfig?

    enum Category: String, Codable { case nature, urban, tonal }

    struct GeneratorConfig: Equatable, Codable {
        enum GeneratorType: String, Codable { case whiteNoise, pinkNoise, brownNoise, binauralBeats, isochronic }
        let type: GeneratorType
        let carrierFrequency: Double?
        let beatFrequency: Double?
        let pulseRate: Double?
    }
}
