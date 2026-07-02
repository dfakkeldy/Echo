// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
struct FlashcardReviewMetadataTests {
    @Test func legacyRowsDecodeWithNilFlags() throws {
        let legacy = #"{"cardId":"c1","grade":3,"intervalDays":2}"#
        let decoded = try #require(FlashcardReviewMetadata.decode(legacy))
        #expect(decoded.grade == 3)
        #expect(decoded.auto == nil)
        #expect(decoded.skipped == nil)
    }

    @Test func autoFlagRoundTrips() throws {
        let metadata = FlashcardReviewMetadata(
            cardID: "c1", grade: 1, intervalDays: 4, auto: true)
        let json = try metadata.encodedJSONString()
        let decoded = try #require(FlashcardReviewMetadata.decode(json))
        #expect(decoded.auto == true)
        #expect(decoded.skipped == nil)
    }

    @Test func skipMarkerRoundTrips() throws {
        let metadata = FlashcardReviewMetadata(
            cardID: "c1", grade: 0, intervalDays: nil, skipped: true)
        let json = try metadata.encodedJSONString()
        let decoded = try #require(FlashcardReviewMetadata.decode(json))
        #expect(decoded.skipped == true)
        #expect(decoded.grade == 0)
    }

    @Test func tapGradesOmitTheAutoKeyEntirely() throws {
        let json = try FlashcardReviewMetadata(cardID: "c1", grade: 3, intervalDays: 1)
            .encodedJSONString()
        #expect(!json.contains("auto"))
        #expect(!json.contains("skipped"))
    }
}
