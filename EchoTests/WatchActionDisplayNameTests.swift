// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct WatchActionDisplayNameTests {
    @Test func displayNamesMatchDesignerLabels() {
        #expect(WatchAction.playPause.displayName == "Play / Pause")
        #expect(WatchAction.skipForward.displayName == "Skip Forward")
        #expect(WatchAction.skipBackward.displayName == "Skip Back")
        #expect(WatchAction.nextTrack.displayName == "Next Chapter")
        #expect(WatchAction.previousTrack.displayName == "Previous Chapter")
        #expect(WatchAction.nextSection.displayName == "Next Section")
        #expect(WatchAction.previousSection.displayName == "Previous Section")
        #expect(WatchAction.loopMode.displayName == "Loop Mode")
        #expect(WatchAction.speed.displayName == "Speed")
        #expect(WatchAction.sleepTimer.displayName == "Sleep Timer")
        #expect(WatchAction.bookmark.displayName == "Bookmark")
        #expect(WatchAction.markPassage.displayName == "Mark Passage")
        #expect(WatchAction.pomodoro.displayName == "Pomodoro")
        #expect(WatchAction.empty.displayName == "Empty")
    }
}
