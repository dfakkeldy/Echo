import Foundation

enum TranscriptionCLIEvent: Codable, Equatable {
    case status(message: String)
    case progress(Double)
    case segment(TranscriptionSegment)
    case wordFrequencies(words: [CLIWordFrequency])
    case completed(outputPath: String, segmentCount: Int, wordFrequencyPath: String?)
    case error(message: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case message
        case progress
        case segment
        case words
        case outputPath
        case segmentCount
        case wordFrequencyPath
    }

    private enum EventType: String, Codable {
        case status
        case progress
        case segment
        case wordFrequencies
        case completed
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(EventType.self, forKey: .type)

        switch type {
        case .status:
            self = .status(message: try container.decode(String.self, forKey: .message))
        case .progress:
            self = .progress(try container.decode(Double.self, forKey: .progress))
        case .segment:
            self = .segment(try container.decode(TranscriptionSegment.self, forKey: .segment))
        case .wordFrequencies:
            self = .wordFrequencies(words: try container.decode([CLIWordFrequency].self, forKey: .words))
        case .completed:
            self = .completed(
                outputPath: try container.decode(String.self, forKey: .outputPath),
                segmentCount: try container.decode(Int.self, forKey: .segmentCount),
                wordFrequencyPath: try container.decodeIfPresent(String.self, forKey: .wordFrequencyPath)
            )
        case .error:
            self = .error(message: try container.decode(String.self, forKey: .message))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .status(let message):
            try container.encode(EventType.status, forKey: .type)
            try container.encode(message, forKey: .message)
        case .progress(let progress):
            try container.encode(EventType.progress, forKey: .type)
            try container.encode(progress, forKey: .progress)
        case .segment(let segment):
            try container.encode(EventType.segment, forKey: .type)
            try container.encode(segment, forKey: .segment)
        case .wordFrequencies(let words):
            try container.encode(EventType.wordFrequencies, forKey: .type)
            try container.encode(words, forKey: .words)
        case .completed(let outputPath, let segmentCount, let wordFrequencyPath):
            try container.encode(EventType.completed, forKey: .type)
            try container.encode(outputPath, forKey: .outputPath)
            try container.encode(segmentCount, forKey: .segmentCount)
            try container.encodeIfPresent(wordFrequencyPath, forKey: .wordFrequencyPath)
        case .error(let message):
            try container.encode(EventType.error, forKey: .type)
            try container.encode(message, forKey: .message)
        }
    }

    func jsonLine() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(self), as: UTF8.self) + "\n"
    }

    func emit(to handle: FileHandle = .standardOutput) throws {
        try handle.write(contentsOf: Data(try jsonLine().utf8))
    }
}
