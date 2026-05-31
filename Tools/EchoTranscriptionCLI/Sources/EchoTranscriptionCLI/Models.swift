import Foundation

/// Mirrors the Codable schema of the iOS app's TranscriptionSegment.
struct TranscriptionSegment: Codable, Equatable {
    let text: String
    let startTime: TimeInterval
    let endTime: TimeInterval
}

/// A word and its occurrence count, matching the iOS/macOS WordFrequency schema.
struct CLIWordFrequency: Codable, Equatable {
    let word: String
    let count: Int
}
