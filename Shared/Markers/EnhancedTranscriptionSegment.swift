import Foundation

/// Decoded representation of an enhanced transcription segment produced by
/// `OrbitTranscriptionCLI align`. Carries Whisper timestamps plus EPUB structural
/// markers injected during alignment.
///
/// Mirrors `OrbitEPUBAligner.EnhancedTranscriptionSegment` so the iOS app can
/// decode enhanced transcripts without depending on the CLI tool's Swift Package.
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
