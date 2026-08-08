// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct ReaderLifecycleStateTests {
    @Test func viewportAnchorSurvivesRecreationForTheSameBookOnly() {
        let bookA = URL(fileURLWithPath: "/books/a")
        let bookB = URL(fileURLWithPath: "/books/b")
        var state = ReaderViewportState(bookIdentityURL: bookA)
        let anchor = ReaderViewportAnchor(
            itemID: "b-paragraph-17",
            distanceFromContentOffset: 28
        )
        state.anchor = anchor

        state.prepare(for: bookA)
        #expect(state.anchor == anchor)

        state.prepare(for: bookB)
        #expect(state.anchor == nil)
    }

    @Test func eachNonzeroReturnRequestCanBeClaimedExactlyOnce() {
        var tracker = ReaderReturnRequestTracker()

        #expect(tracker.claim(0) == false)
        #expect(tracker.claim(1))
        #expect(tracker.claim(1) == false)
        #expect(tracker.claim(2))
        #expect(tracker.claim(2) == false)
    }
}
