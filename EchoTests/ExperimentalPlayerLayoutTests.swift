// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct ExperimentalPlayerLayoutTests {

    @Test func defaultLayoutHasCoreTransportAndFiveButtons() {
        let layout = ExperimentalPlayerLayout.defaultLayout
        #expect(layout.buttons.count == 5)
        #expect(layout.buttons.contains { $0.action == .playPause && $0.zone == .lowerCenter })
        #expect(layout.buttons.contains { $0.action == .skipBackward && $0.zone == .lowerLeading })
        #expect(layout.buttons.contains { $0.action == .skipForward && $0.zone == .lowerTrailing })
    }

    @Test func codecRoundTrips() {
        let layout = ExperimentalPlayerLayout.defaultLayout
        let decoded = ExperimentalPlayerLayout.decode(layout.encoded())
        #expect(decoded == layout)
    }

    @Test func garbageDataFallsBackToDefault() {
        let decoded = ExperimentalPlayerLayout.decode(Data("not json".utf8))
        #expect(decoded == ExperimentalPlayerLayout.defaultLayout)
    }

    @Test func emptyDataFallsBackToDefault() {
        #expect(ExperimentalPlayerLayout.decode(Data()) == ExperimentalPlayerLayout.defaultLayout)
    }

    @Test func addingAppendsToFirstFreeZoneAndIgnoresDuplicates() {
        let layout = ExperimentalPlayerLayout.defaultLayout  // occupies lowerL/C/T, midL, midT
        let added = layout.adding(.sleepTimer)
        #expect(added.buttons.count == 6)
        #expect(added.buttons.last?.action == .sleepTimer)
        #expect(added.buttons.last?.zone == .upperLeading)  // first free zone in allCases order
        #expect(added.adding(.sleepTimer) == added)  // no duplicates
    }

    @Test func removingDeletesOnlyThatAction() {
        let removed = ExperimentalPlayerLayout.defaultLayout.removing(.bookmark)
        #expect(removed.buttons.count == 4)
        #expect(!removed.buttons.contains { $0.action == .bookmark })
    }

    @Test func movingUpdatesZoneAndOffset() {
        let moved = ExperimentalPlayerLayout.defaultLayout.moving(
            .playPause, to: .upperLeading, offset: CGSize(width: 10, height: -5))
        let play = moved.buttons.first { $0.action == .playPause }
        #expect(play?.zone == .upperLeading)
        #expect(play?.offset == CGSize(width: 10, height: -5))
    }

    @Test func availableActionsExcludesConfiguredAndNonButtons() {
        let available = ExperimentalPlayerLayout.defaultLayout.availableActions
        #expect(!available.contains(.playPause))
        #expect(!available.contains(.empty))
        #expect(!available.contains(.pomodoro))
        #expect(available.contains(.sleepTimer))
    }
}
