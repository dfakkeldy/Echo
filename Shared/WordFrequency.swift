import Foundation

/// A word and its occurrence count, used for word cloud rendering.
public struct WordFrequency: Codable, Hashable, Identifiable {
    public var id: String { word }
    public let word: String
    public let count: Int

    public init(word: String, count: Int) {
        self.word = word
        self.count = count
    }
}
