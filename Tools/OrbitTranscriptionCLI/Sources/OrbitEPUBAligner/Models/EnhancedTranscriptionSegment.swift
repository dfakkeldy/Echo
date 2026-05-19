import Foundation

public struct EnhancedTranscriptionSegment: Codable, Identifiable {
    public var id: String { "\(sequenceIndex)" }

    /// Monotonic ordering index within the full EPUB spine.
    /// Timestamped and un-timestamped segments share one sequence.
    public let sequenceIndex: Int

    public let text: String

    /// `nil` for EPUB-only blocks (images, footnotes, skipped text) that
    /// have no corresponding audio. The timeline feed renders these in
    /// correct EPUB order but tapping them does not seek the player.
    public let startTime: TimeInterval?
    public let endTime: TimeInterval?

    public let markers: [SyncMarker]?
    public let formatting: [TextFormat]?

    public var isTimestamped: Bool {
        startTime != nil && endTime != nil
    }

    public init(
        sequenceIndex: Int,
        text: String,
        startTime: TimeInterval?,
        endTime: TimeInterval?,
        markers: [SyncMarker]? = nil,
        formatting: [TextFormat]? = nil
    ) {
        self.sequenceIndex = sequenceIndex
        self.text = text
        self.startTime = startTime
        self.endTime = endTime
        self.markers = markers
        self.formatting = formatting
    }
}
