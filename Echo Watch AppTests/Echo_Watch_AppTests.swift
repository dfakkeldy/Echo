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

}
