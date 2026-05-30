import Foundation

/// A single M4B file within a multi-M4B folder, with its parsed metadata and chapters.
struct M4BBook: Identifiable, Equatable, Hashable, Sendable {
    var id: String { url.absoluteString }
    let url: URL
    let title: String
    let duration: TimeInterval
    let chapters: [Chapter]
    var cumulativeStartOffset: TimeInterval = 0
    var trackIndex: Int = 0
}
