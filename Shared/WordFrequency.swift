// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A word and its occurrence count, used for word cloud rendering.
// `nonisolated`: pure `Sendable` value type, embedded in the now-`nonisolated`
// `Chapter`. Without this its synthesized conformances would be `@MainActor` under
// the iOS target's Swift 6 default isolation, re-isolating `Chapter`.
public nonisolated struct WordFrequency: Codable, Hashable, Identifiable, Sendable {
    public var id: String { word }
    public let word: String
    public let count: Int

    public init(word: String, count: Int) {
        self.word = word
        self.count = count
    }
}
