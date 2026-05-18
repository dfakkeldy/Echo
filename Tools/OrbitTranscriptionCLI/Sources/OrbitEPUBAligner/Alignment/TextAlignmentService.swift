import Foundation

public protocol TextAlignmentService {
    func align(
        epubText: String,
        transcript: [EnhancedTranscriptionSegment]
    ) async throws -> [AlignmentResult]
}
