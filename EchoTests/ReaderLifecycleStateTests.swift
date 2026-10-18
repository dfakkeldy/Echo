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
            distanceFromContentOffset: 28,
            openChapterKey: 3
        )
        state.anchor = anchor

        state.prepare(for: bookA)
        #expect(state.anchor == anchor)

        state.prepare(for: bookB)
        #expect(state.anchor == nil)
    }

    @Test func staleBookGenerationCannotReplaceTheClearedViewport() {
        let bookA = URL(fileURLWithPath: "/books/a")
        let bookB = URL(fileURLWithPath: "/books/b")
        var state = ReaderViewportState(bookIdentityURL: bookA)
        let staleContext = state.publicationContext

        state.prepare(for: bookB)
        state.prepare(for: bookA)

        let staleAnchor = ReaderViewportAnchor(
            itemID: "note-from-a",
            distanceFromContentOffset: 12,
            openChapterKey: 4
        )
        let appliedStalePublication = state.apply(
            ReaderViewportPublication(context: staleContext, anchor: staleAnchor)
        )
        #expect(appliedStalePublication == false)
        #expect(state.anchor == nil)

        let currentAnchor = ReaderViewportAnchor(
            itemID: "memo-from-current-a",
            distanceFromContentOffset: 20,
            openChapterKey: 2
        )
        let appliedCurrentPublication = state.apply(
            ReaderViewportPublication(
                context: state.publicationContext,
                anchor: currentAnchor
            )
        )
        #expect(appliedCurrentPublication)
        #expect(state.anchor == currentAnchor)
    }

    @Test func eachNonzeroReturnRequestCanBeClaimedExactlyOnce() {
        var tracker = ReaderReturnRequestTracker()

        let claimedZero = tracker.claim(0)
        #expect(claimedZero == false)
        let claimedFirstRequest = tracker.claim(1)
        #expect(claimedFirstRequest)
        let claimedDuplicateFirstRequest = tracker.claim(1)
        #expect(claimedDuplicateFirstRequest == false)
        let claimedSecondRequest = tracker.claim(2)
        #expect(claimedSecondRequest)
        let claimedDuplicateSecondRequest = tracker.claim(2)
        #expect(claimedDuplicateSecondRequest == false)
    }
}
