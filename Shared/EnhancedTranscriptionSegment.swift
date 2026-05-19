import Foundation

public struct EnhancedTranscriptionSegment: Codable, Identifiable {
    public var id: String { "\(startTime)-\(endTime)" }
    public let text: String
    public let startTime: TimeInterval
    public let endTime: TimeInterval
    public let markers: [SyncMarker]?
    public let formatting: [TextFormat]?

    public init(
        text: String,
        startTime: TimeInterval,
        endTime: TimeInterval,
        markers: [SyncMarker]? = nil,
        formatting: [TextFormat]? = nil
    ) {
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.markers = markers
        self.formatting = formatting
    }
}

public struct TextFormat: Codable, Equatable {
    public let type: FormatType
    public let range: ClosedRange<Int>

    public init(type: FormatType, range: ClosedRange<Int>) {
        self.type = type
        self.range = range
    }
}

public enum FormatType: String, Codable, Equatable {
    case bold
    case italic
    case underline
    case strikethrough
    case superscript
    case smallCaps
}
