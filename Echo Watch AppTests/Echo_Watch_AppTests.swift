// SPDX-License-Identifier: GPL-3.0-or-later
//
//  Echo_Watch_AppTests.swift
//  Echo Watch AppTests
//
//  Created by Dan Fakkeldy on 2026-05-02.
//

import Foundation
import Testing
@testable import Echo_Watch_App

struct Echo_Watch_AppTests {

    @Test func watchActionCommandsMatchPhoneCommandNames() {
        #expect(WatchAction.playPause.command == "toggle")
        #expect(WatchAction.skipForward.command == "skipForward")
        #expect(WatchAction.skipBackward.command == "skipBackward")
        #expect(WatchAction.nextTrack.command == "next")
        #expect(WatchAction.previousTrack.command == "previous")
        #expect(WatchAction.loopMode.command == "cycleLoopMode")
        #expect(WatchAction.speed.command == "cycleSpeed")
        #expect(WatchAction.sleepTimer.command == "toggleSleepTimer")
        #expect(WatchAction.bookmark.command == "addBookmark")
        #expect(WatchAction.pomodoro.command == "pomodoro")
        #expect(WatchAction.empty.command == "")
    }

    @Test func watchActionsRoundtripJSON() throws {
        let original: [WatchAction] = [.skipBackward, .playPause, .empty, .empty, .empty]
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode([WatchAction].self, from: data)

        #expect(decoded == original)
    }

    @Test func watchActionsMigrationFromOldStringFormat() throws {
        let oldString = "skipBackward,nope,playPause"

        // Simulate the migration path: parse old comma-separated string
        let parsed = oldString.split(separator: ",").compactMap { WatchAction(rawValue: String($0)) }
        var padded = Array(parsed.prefix(5))
        while padded.count < 5 { padded.append(.empty) }

        // Unknown actions (like "nope") are dropped
        #expect(padded == [.skipBackward, .playPause, .empty, .empty, .empty])

        // Verify the result roundtrips through JSON
        let data = try JSONEncoder().encode(padded)
        let decoded = try JSONDecoder().decode([WatchAction].self, from: data)
        #expect(decoded == padded)
    }

    @Test func wakeRefreshPolicyAllowsInitialRefreshAndThrottlesDuplicates() {
        var policy = WatchWakeRefreshPolicy(minimumInterval: 1.0)
        let start = Date(timeIntervalSinceReferenceDate: 100)
        let firstRefresh = policy.shouldRefresh(now: start)
        let duplicateRefresh = policy.shouldRefresh(now: start.addingTimeInterval(0.5))
        let laterRefresh = policy.shouldRefresh(now: start.addingTimeInterval(1.0))

        #expect(firstRefresh)
        #expect(!duplicateRefresh)
        #expect(laterRefresh)
    }

    @Test func wakeRefreshPolicyDoesNotThrottleUntilRefreshIsRecorded() {
        var policy = WatchWakeRefreshPolicy(minimumInterval: 1.0)
        let start = Date(timeIntervalSinceReferenceDate: 100)

        #expect(policy.canRefresh(now: start))
        #expect(policy.canRefresh(now: start.addingTimeInterval(0.5)))

        policy.recordRefresh(now: start.addingTimeInterval(0.5))

        #expect(!policy.canRefresh(now: start.addingTimeInterval(1.0)))
        #expect(policy.canRefresh(now: start.addingTimeInterval(1.5)))
    }

    @MainActor
    @Test func receivedApplicationContextUpdatesWatchState() async {
        let viewModel = WatchViewModel()
        let applied = viewModel.applyReceivedApplicationContext([
            "title": "Updated on iPhone",
            "currentTime": 42.0,
            "totalProgressFraction": 0.25,
            "progressFraction": 0.5
        ])

        await Task.yield()

        #expect(applied)
        #expect(viewModel.title == "Updated on iPhone")
        #expect(viewModel.currentTime == 42.0)
        #expect(viewModel.totalProgressFraction == 0.25)
        #expect(viewModel.progressFraction == 0.5)
    }

}
