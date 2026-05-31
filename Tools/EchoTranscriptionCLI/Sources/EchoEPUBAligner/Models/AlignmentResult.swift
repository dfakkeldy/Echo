import Foundation

public struct AlignmentResult {
    public let epubCharRange: ClosedRange<Int>
    public let transcriptTimeRange: ClosedRange<TimeInterval>
    public let confidence: Double
    public let containedMarkers: [SyncMarker]

    public init(epubCharRange: ClosedRange<Int>, transcriptTimeRange: ClosedRange<TimeInterval>, confidence: Double, containedMarkers: [SyncMarker]) {
        self.epubCharRange = epubCharRange
        self.transcriptTimeRange = transcriptTimeRange
        self.confidence = confidence
        self.containedMarkers = containedMarkers
    }
}
