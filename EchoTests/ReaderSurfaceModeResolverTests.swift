// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct ReaderSurfaceModeResolverTests {
    @Test func parsedPDFOffersPageThenReflow() {
        #expect(
            ReaderSurfaceResolver.availableModes(hasPDF: true, hasReflowableBlocks: true)
                == [.page, .reflow])
        #expect(ReaderSurfaceResolver.offersToggle(hasPDF: true, hasReflowableBlocks: true))
    }

    @Test func unparsedPDFOffersPageOnly() {
        #expect(
            ReaderSurfaceResolver.availableModes(hasPDF: true, hasReflowableBlocks: false)
                == [.page])
        #expect(!ReaderSurfaceResolver.offersToggle(hasPDF: true, hasReflowableBlocks: false))
    }

    @Test func nonPDFOffersNothing() {
        #expect(
            ReaderSurfaceResolver.availableModes(hasPDF: false, hasReflowableBlocks: true)
                .isEmpty)
        #expect(!ReaderSurfaceResolver.offersToggle(hasPDF: false, hasReflowableBlocks: true))
    }

    @Test func pendingReturnWhileExploringRoutesPageModeToReflow() {
        var tracker = ReaderReturnRequestTracker()
        let request = 1
        let destination = ReaderSurfaceReturnPolicy.destination(
            currentMode: .page,
            followState: .exploring,
            hasPendingReturnRequest: tracker.hasPending(request)
        )

        #expect(destination == .reflow)
        let claimedRequest = tracker.claim(request)
        #expect(claimedRequest)
        let claimedDuplicateRequest = tracker.claim(request)
        #expect(claimedDuplicateRequest == false)
        #expect(
            ReaderSurfaceReturnPolicy.destination(
                currentMode: destination,
                followState: .exploring,
                hasPendingReturnRequest: tracker.hasPending(request)
            ) == destination
        )
        #expect(
            ReaderSurfaceReturnPolicy.destination(
                currentMode: .page,
                followState: .following,
                hasPendingReturnRequest: true
            ) == .page
        )
        #expect(
            ReaderSurfaceReturnPolicy.destination(
                currentMode: .page,
                followState: .exploring,
                hasPendingReturnRequest: false
            ) == .page
        )
    }
}
