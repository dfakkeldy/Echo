import Foundation

public struct TranscriptionSegment: Codable, Identifiable {
    /// Stable ID derived from integer milliseconds, avoiding floating-point
    /// imprecision in the string representation (e.g. "0.1" vs "0.10000000000000001").
    public var id: String {
        let startMs = Int((startTime * 1000).rounded())
        let endMs = Int((endTime * 1000).rounded())
        return "\(startMs)-\(endMs)"
    }
    public let text: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval

    public init(text: String, startTime: TimeInterval, endTime: TimeInterval) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
    }
}
