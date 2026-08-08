// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import Testing
import UIKit

@testable import Echo

@MainActor
@Suite struct ReaderFeedFollowCoordinatorTests {
    @Test func dragDetachesAndInvalidatesQueuedPlaybackScroll() {
        let followState = MutableBox(ReaderFollowState.following)
        let headerVisible = MutableBox(true)
        let part = MutableBox<String?>(nil)
        let chapter = MutableBox<String?>(nil)
        let section = MutableBox<String?>(nil)
        let theme = MutableBox<String?>(nil)

        let coordinator = ReaderFeedCollectionView.Coordinator(
            onTapBlock: nil,
            onTapWord: nil,
            onContextMenu: nil,
            onAccessibilityActions: nil,
            isHeaderVisible: binding(headerVisible),
            followState: binding(followState),
            topPartTitle: binding(part),
            topChapterTitle: binding(chapter),
            topSectionTitle: binding(section),
            topChapterThemeColor: binding(theme)
        )
        let scheduledGeneration = coordinator.scrollGeneration

        coordinator.scrollViewWillBeginDragging(UIScrollView())

        #expect(followState.value == .exploring)
        #expect(coordinator.scrollGeneration == scheduledGeneration &+ 1)
        #expect(
            coordinator.mayApplyScroll(
                intent: .followPlayback,
                scheduledGeneration: scheduledGeneration
            ) == false
        )
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
