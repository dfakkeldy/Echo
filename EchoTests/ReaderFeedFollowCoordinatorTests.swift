// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import Testing
import UIKit

@testable import Echo

@MainActor
@Suite struct ReaderFeedFollowCoordinatorTests {
    @Test func dragDetachesAndInvalidatesQueuedPlaybackScroll() {
        let followState = MutableBox(ReaderFollowState.following)
        let coordinator = makeCoordinator(followState: followState)
        let scheduledGeneration = coordinator.scrollGeneration
        #expect(coordinator.shouldStartFollowScroll(to: 240, scheduledGeneration: scheduledGeneration))

        coordinator.scrollViewWillBeginDragging(UIScrollView())

        #expect(followState.value == .exploring)
        #expect(coordinator.scrollGeneration == scheduledGeneration &+ 1)
        #expect(
            coordinator.mayApplyScroll(
                intent: .followPlayback,
                scheduledGeneration: scheduledGeneration
            ) == false
        )
        #expect(
            coordinator.shouldStartFollowScroll(to: 240, scheduledGeneration: scheduledGeneration)
                == false
        )
    }

    @Test func sameLineTargetIsNotRescheduledWhileItsScrollIsInFlight() {
        let followState = MutableBox(ReaderFollowState.following)
        let coordinator = makeCoordinator(followState: followState)
        let scheduledGeneration = coordinator.scrollGeneration

        #expect(coordinator.shouldStartFollowScroll(to: 240, scheduledGeneration: scheduledGeneration))
        #expect(
            coordinator.shouldStartFollowScroll(to: 240.25, scheduledGeneration: scheduledGeneration)
                == false
        )
        #expect(coordinator.shouldStartFollowScroll(to: 241, scheduledGeneration: scheduledGeneration))

        coordinator.scrollViewWillBeginDragging(UIScrollView())
        followState.value = .following
        #expect(
            coordinator.shouldStartFollowScroll(
                to: 240,
                scheduledGeneration: coordinator.scrollGeneration
            )
        )
    }

    @Test func returnCompletionRequiresResolvedFinalGeometry() {
        let followState = MutableBox(ReaderFollowState.exploring)
        let results = MutableBox<[Bool]>([])
        let coordinator = makeCoordinator(followState: followState) { result in
            results.value.append(result)
        }

        #expect(coordinator.reportReturnTargetResolution(for: nil) == false)
        #expect(coordinator.reportReturnTargetResolution(for: 100 ... 140))
        #expect(results.value == [false, true])
    }

    @Test func recreatedCoordinatorRestoresRootOwnedViewportAnchor() {
        let followState = MutableBox(ReaderFollowState.exploring)
        let viewportAnchor = ReaderViewportAnchor(
            itemID: "bm-saved",
            distanceFromContentOffset: 28,
            openChapterKey: 1
        )
        let firstCoordinator = makeCoordinator(
            followState: followState,
            viewportAnchor: viewportAnchor
        )
        #expect(
            firstCoordinator.restoredContentOffsetY(
                forItemID: "bm-saved",
                itemFrameMinY: 328
            ) == 300
        )

        let recreatedCoordinator = makeCoordinator(
            followState: followState,
            viewportAnchor: viewportAnchor
        )
        #expect(
            recreatedCoordinator.restoredContentOffsetY(
                forItemID: "bm-saved",
                itemFrameMinY: 428
            ) == 400
        )
        #expect(
            recreatedCoordinator.restoredContentOffsetY(
                forItemID: "b-another-paragraph",
                itemFrameMinY: 428
            ) == nil
        )
    }

    @Test func sameSnapshotRestorationUsesCapturedAnchorInsteadOfStaleRootAnchor() {
        let followState = MutableBox(ReaderFollowState.exploring)
        let staleRootAnchor = ReaderViewportAnchor(
            itemID: "b-stale",
            distanceFromContentOffset: 100,
            openChapterKey: 0
        )
        let capturedAnchor = ReaderViewportAnchor(
            itemID: "bm-current",
            distanceFromContentOffset: 28,
            openChapterKey: 1
        )
        let coordinator = makeCoordinator(
            followState: followState,
            viewportAnchor: staleRootAnchor
        )

        #expect(
            coordinator.restoredContentOffsetY(
                from: capturedAnchor,
                forItemID: "bm-current",
                itemFrameMinY: 328
            ) == 300
        )
    }

    private func makeCoordinator(
        followState: MutableBox<ReaderFollowState>,
        viewportAnchor: ReaderViewportAnchor? = nil,
        onReturnTargetResolved: ((Bool) -> Void)? = nil
    ) -> ReaderFeedCollectionView.Coordinator {
        let viewportState = ReaderViewportState(
            bookIdentityURL: URL(fileURLWithPath: "/books/current"),
            anchor: viewportAnchor
        )
        let coordinator = ReaderFeedCollectionView.Coordinator(
            onTapBlock: nil,
            onTapWord: nil,
            onContextMenu: nil,
            onAccessibilityActions: nil,
            isHeaderVisible: .constant(true),
            followState: binding(followState),
            viewportAnchor: viewportAnchor,
            viewportPublicationContext: viewportState.publicationContext,
            onViewportAnchorCaptured: nil,
            openChapterKey: viewportAnchor?.openChapterKey,
            topPartTitle: Binding<String?>.constant(nil),
            topChapterTitle: Binding<String?>.constant(nil),
            topSectionTitle: Binding<String?>.constant(nil),
            topChapterThemeColor: Binding<String?>.constant(nil)
        )
        coordinator.onReturnTargetResolved = onReturnTargetResolved
        return coordinator
    }

    private func binding<Value>(_ box: MutableBox<Value>) -> Binding<Value> {
        Binding(
            get: { box.value },
            set: { box.value = $0 }
        )
    }
}

@MainActor
private final class MutableBox<Value> {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}
