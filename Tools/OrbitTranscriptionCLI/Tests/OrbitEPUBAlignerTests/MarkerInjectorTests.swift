import Foundation
import Testing
@testable import OrbitEPUBAligner

@Test func testMarkerAtExactSegment() throws {
    let injector = MarkerInjector()
    let marker = SyncMarker(type: .image, payload: "map.jpg", epubCharOffset: 50)
    let alignmentResults = [
        AlignmentResult(epubCharRange: 0...100, transcriptTimeRange: 0...5, confidence: 0.95, containedMarkers: [marker])
    ]
    let segments = [EnhancedTranscriptionSegment(text: "Hello world.", startTime: 0, endTime: 5)]
    let enhanced = injector.inject(markers: [marker], alignments: alignmentResults, segments: segments)
    #expect(enhanced.count == 1)
    #expect(enhanced[0].markers?.count == 1)
    #expect(enhanced[0].markers?.first?.type == .image)
}

@Test func testMarkerBetweenSegmentsAssignsToNearest() throws {
    let injector = MarkerInjector()
    let marker = SyncMarker(type: .chapterStart, payload: "Chapter 1", epubCharOffset: 95)
    let alignmentResults = [
        AlignmentResult(epubCharRange: 0...90, transcriptTimeRange: 0...5, confidence: 0.90, containedMarkers: []),
        AlignmentResult(epubCharRange: 91...200, transcriptTimeRange: 5...10, confidence: 0.90, containedMarkers: [marker])
    ]
    let segments = [
        EnhancedTranscriptionSegment(text: "Part one.", startTime: 0, endTime: 5),
        EnhancedTranscriptionSegment(text: "Part two.", startTime: 5, endTime: 10),
    ]
    let enhanced = injector.inject(markers: [marker], alignments: alignmentResults, segments: segments)
    #expect(enhanced.count == 2)
    let seg1Markers = enhanced[1].markers ?? []
    #expect(seg1Markers.contains(where: { $0.payload == "Chapter 1" }))
}

@Test func testMultipleMarkersInSameSegment() throws {
    let injector = MarkerInjector()
    let imgMarker = SyncMarker(type: .image, payload: "cover.jpg", epubCharOffset: 10)
    let headingMarker = SyncMarker(type: .chapterStart, payload: "Prologue", epubCharOffset: 45)
    let alignmentResults = [
        AlignmentResult(epubCharRange: 0...100, transcriptTimeRange: 0...5, confidence: 0.95, containedMarkers: [imgMarker, headingMarker])
    ]
    let segments = [EnhancedTranscriptionSegment(text: "Prologue text.", startTime: 0, endTime: 5)]
    let enhanced = injector.inject(markers: [imgMarker, headingMarker], alignments: alignmentResults, segments: segments)
    let segMarkers = enhanced[0].markers ?? []
    #expect(segMarkers.count == 2)
}

@Test func testNoMarkersProducesNilMarkerField() throws {
    let injector = MarkerInjector()
    let alignmentResults = [
        AlignmentResult(epubCharRange: 0...50, transcriptTimeRange: 0...3, confidence: 1.0, containedMarkers: [])
    ]
    let segments = [EnhancedTranscriptionSegment(text: "Plain text.", startTime: 0, endTime: 3)]
    let enhanced = injector.inject(markers: [], alignments: alignmentResults, segments: segments)
    #expect(enhanced[0].markers == nil)
}
