import Foundation

/// A word and its occurrence count, used for word cloud rendering.
struct WordFrequency: Codable, Hashable, Identifiable {
    var id: String { word }
    let word: String
    let count: Int
}
