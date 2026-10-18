// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct PronunciationContributionPayloadTests {
    @Test func encodesOnlyAllowedFields() throws {
        let payload = PronunciationContributionPayload(
            term: "Cholmondeley",
            ipa: "\u{2C8}t\u{0283}\u{028C}mli",
            language: "en",
            voiceModelVersion: "kokoro-v1.0",
            confidence: 0.92)
        let data = try JSONEncoder().encode(payload)
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        // Exactly the five allowed keys — no surrounding-prose carrier fields.
        #expect(Set(json.keys) == ["term", "ipa", "language", "voiceModelVersion", "confidence"])
        #expect(json["term"] as? String == "Cholmondeley")
        #expect(json["ipa"] as? String == "\u{2C8}t\u{0283}\u{028C}mli")
    }

    @Test func roundTrips() throws {
        let payload = PronunciationContributionPayload(
            term: "data", ipa: "\u{2C8}de\u{26A} t\u{259}", language: "en",
            voiceModelVersion: "kokoro-v1.0", confidence: 0.5)
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(
            PronunciationContributionPayload.self, from: data)
        #expect(decoded == payload)
    }
}
