import Foundation
import Testing
@testable import OrbitEPUBAligner

@Test func testPerfectMatch() async throws {
    let aligner = SlidingWindowAligner()
    let segments = [
        EnhancedTranscriptionSegment(text: "It was a dark and stormy night.", startTime: 0, endTime: 3),
        EnhancedTranscriptionSegment(text: "The captain spoke quietly.", startTime: 3, endTime: 6),
    ]
    let epubText = "It was a dark and stormy night. The captain spoke quietly."
    let results = try await aligner.align(epubText: epubText, transcript: segments)
    #expect(results.count == 2)
    #expect(results[0].confidence > 0.90)
    #expect(results[1].confidence > 0.90)
}

@Test func testSlightWhisperError() async throws {
    let aligner = SlidingWindowAligner()
    let segments = [
        EnhancedTranscriptionSegment(text: "It was a dark and stormy knight.", startTime: 0, endTime: 3),
    ]
    let epubText = "It was a dark and stormy night."
    let results = try await aligner.align(epubText: epubText, transcript: segments)
    #expect(results.count == 1)
    #expect(results[0].confidence > 0.75)
}

@Test func testMonotonicOutput() async throws {
    let aligner = SlidingWindowAligner()
    let segments = [
        EnhancedTranscriptionSegment(text: "First sentence.", startTime: 0, endTime: 2),
        EnhancedTranscriptionSegment(text: "Third sentence.", startTime: 2, endTime: 4),
    ]
    let epubText = "First sentence. Second sentence. Third sentence."
    let results = try await aligner.align(epubText: epubText, transcript: segments)
    guard results.count >= 2 else { return }
    for i in 1..<results.count {
        #expect(results[i].epubCharRange.lowerBound >= results[i - 1].epubCharRange.lowerBound)
    }
}

@Test func testEmptyTranscriptThrows() async {
    let aligner = SlidingWindowAligner()
    let epubText = "Some meaningful text."
    await #expect(throws: AlignmentError.self) {
        _ = try await aligner.align(epubText: epubText, transcript: [])
    }
}

@Test func testEmptyEPUBTextThrows() async {
    let aligner = SlidingWindowAligner()
    let segments = [EnhancedTranscriptionSegment(text: "Hello world.", startTime: 0, endTime: 2)]
    await #expect(throws: AlignmentError.self) {
        _ = try await aligner.align(epubText: "", transcript: segments)
    }
}
