import Foundation

/// A chapter within an audiobook track, typically parsed from M4B chapter markers.
struct Chapter: Identifiable, Equatable, Hashable, Sendable {
    var id: String { "\(index)-\(title ?? "unknown")" }
    /// Zero-based chapter index.
    let index: Int
    /// The chapter title, if available from metadata.
    let title: String?
    /// Start time in seconds within the parent track.
    let startSeconds: Double
    /// End time in seconds within the parent track.
    let endSeconds: Double
    /// Whether the chapter is included during sequential playback.
    var isEnabled: Bool = true
    /// Pre-computed word frequencies for this chapter (nil until generated).
    var wordCloudFrequencies: [WordFrequency]?
}
