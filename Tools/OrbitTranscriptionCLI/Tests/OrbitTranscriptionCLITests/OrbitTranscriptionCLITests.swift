import Foundation
import Testing
@testable import OrbitTranscriptionCLI

@Test func segmentEncodingMatchesExpectedSchema() throws {
    let segments = [
        TranscriptionSegment(text: "Hello world.", startTime: 0.0, endTime: 2.5),
        TranscriptionSegment(text: "This is a test.", startTime: 2.5, endTime: 5.0),
    ]
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(segments)

    let decoded = try JSONDecoder().decode([TranscriptionSegment].self, from: data)
    #expect(decoded.count == 2)
    #expect(decoded[0].text == "Hello world.")
    #expect(decoded[0].startTime == 0.0)
    #expect(decoded[0].endTime == 2.5)

    // Verify JSON structure has no unexpected keys
    let json = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]
    let keys = Set(json[0].keys)
    #expect(keys == ["endTime", "startTime", "text"])
}
