// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct MarkedPassageCaptureTests {
    private struct PersistenceFailure: Error {}

    @Test func savedBuildsTheExpectedTwentySecondWindow() throws {
        var captured: MarkedPassageCaptureRequest?
        let result = MarkedPassageCapture.capture(
            bookID: "book",
            isItemLoaded: true,
            time: 42,
            snippet: "Chapter: Five"
        ) { request in
            captured = request
        }

        #expect(result == .saved)
        #expect(captured?.audiobookID == "book")
        #expect(captured?.mediaTimestamp == 27)
        #expect(captured?.endTimestamp == 47)
        #expect(captured?.transcriptSnippet == "Chapter: Five")
    }

    @Test func missingBookLoadedItemOrFiniteTimeIsUnavailable() {
        #expect(
            MarkedPassageCapture.capture(
                bookID: nil,
                isItemLoaded: true,
                time: 2,
                snippet: nil,
                persist: { _ in }
            ) == .unavailable
        )
        #expect(
            MarkedPassageCapture.capture(
                bookID: "book",
                isItemLoaded: false,
                time: 2,
                snippet: nil,
                persist: { _ in }
            ) == .unavailable
        )
        #expect(
            MarkedPassageCapture.capture(
                bookID: "book",
                isItemLoaded: true,
                time: .infinity,
                snippet: nil,
                persist: { _ in }
            ) == .unavailable
        )
    }

    @Test func persistenceErrorReturnsFailedAndReportsTheError() {
        var reported = false
        let result = MarkedPassageCapture.capture(
            bookID: "book",
            isItemLoaded: true,
            time: 10,
            snippet: nil,
            persist: { _ in throw PersistenceFailure() },
            onFailure: { _ in reported = true }
        )
        #expect(result == .failed)
        #expect(reported)
    }
}
