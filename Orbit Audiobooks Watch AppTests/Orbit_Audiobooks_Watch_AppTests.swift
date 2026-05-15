//
//  Orbit_Audiobooks_Watch_AppTests.swift
//  Orbit Audiobooks Watch AppTests
//
//  Created by Dan Fakkeldy on 2026-05-02.
//

import Testing
@testable import Orbit_Audiobooks_Watch_App

struct Orbit_Audiobooks_Watch_AppTests {

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

    @Test func watchSlotParserPadsToFiveActions() {
        let parsed = WatchSlotConfiguration.actions(from: "skipBackward,playPause")

        #expect(parsed == [.skipBackward, .playPause, .empty, .empty, .empty])
    }

    @Test func watchSlotParserIgnoresUnknownActions() {
        let parsed = WatchSlotConfiguration.actions(from: "skipBackward,nope,playPause")

        #expect(parsed == [.skipBackward, .playPause, .empty, .empty, .empty])
    }

}
