import Foundation

public struct TranscriptionSegment: Codable, Identifiable {
    public var id: String { "\(startTime)-\(endTime)" }
    public let text: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval

    public init(text: String, startTime: TimeInterval, endTime: TimeInterval) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
    }
}
