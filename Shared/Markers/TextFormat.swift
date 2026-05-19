import Foundation

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
