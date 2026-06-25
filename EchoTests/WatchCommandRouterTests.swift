// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Echo

@MainActor
struct WatchCommandRouterTests {
    @Test("navigation commands forward through facade and include bookmark jump reply")
    func navigationCommandReplyIncludesBookmarkJumpAndThumbnail() {
        let facade = FakeWatchCommandFacade()
        facade.navigationShouldBookmarkJump = true
        let router = WatchCommandRouter(facade: facade)

        let reply = self.reply(from: router, message: ["command": "next"])

        #expect(facade.calls == ["skipForwardNavigation"])
        #expect(reply["commandResult"] as? String == "bookmarkJump")
        #expect(reply["thumbnailData"] as? Data == Data([0x01, 0x02, 0x03]))
        #expect(reply["title"] as? String == "Test Book")
    }

    @Test("scrub and volume deltas clamp through facade settings")
    func deltasUseFacadeSettingsAndClampOutputs() {
        let facade = FakeWatchCommandFacade()
        facade.currentPlaybackTime = 190
        facade.durationSeconds = 200
        facade.watchCommandOutputGain = 8
        facade.crownScrubSensitivity = 1
        facade.crownVolumeSensitivity = 1
        let router = WatchCommandRouter(facade: facade)

        _ = self.reply(from: router, message: ["command": "scrubDelta", "delta": 1.0])
        _ = self.reply(from: router, message: ["command": "volumeDelta", "delta": 1.0])

        #expect(facade.seekSeconds == [200])
        #expect(facade.appliedGains == [9])
    }

    @Test("non-positive crown sensitivities fall back to defaults")
    func deltasUseDefaultSensitivityFallbacks() {
        let facade = FakeWatchCommandFacade()
        facade.currentPlaybackTime = 100
        facade.durationSeconds = 200
        facade.crownScrubSensitivity = 0
        facade.crownVolumeSensitivity = 0
        let router = WatchCommandRouter(facade: facade)

        _ = self.reply(from: router, message: ["command": "scrubDelta", "delta": 1.0])
        _ = self.reply(from: router, message: ["command": "volumeDelta", "delta": 1.0])

        #expect(facade.seekSeconds == [115])
        #expect(abs((facade.appliedGains.last ?? -1) - 0.3) < 0.001)
    }

    @Test("speed and sleep timer commands map to facade operations")
    func speedAndSleepTimerCommandsMapToFacade() {
        let facade = FakeWatchCommandFacade()
        facade.speed = 1.5
        let router = WatchCommandRouter(facade: facade)

        _ = self.reply(from: router, message: ["command": "cycleSpeed"])
        _ = self.reply(from: router, message: ["command": "cycleSpeed", "playbackSpeed": 1.75])
        _ = self.reply(from: router, message: [
            "command": "setSleepTimer",
            "sleepTimerMode": "minutes",
            "sleepTimerMinutes": 25
        ])
        _ = self.reply(from: router, message: [
            "command": "setSleepTimer",
            "sleepTimerMode": "endOfChapter"
        ])
        _ = self.reply(from: router, message: ["command": "cancelSleepTimer"])
        _ = self.reply(from: router, message: ["command": "toggleSleepTimer"])

        #expect(facade.setSpeeds == [2.0, 1.75])
        #expect(facade.sleepModes == [.minutes(25), .endOfChapter])
        #expect(facade.calls.contains("cancelSleepTimer"))
        #expect(facade.calls.contains("toggleSleepTimer"))
        #expect(facade.toggleSleepTimerCalled == true)
    }

    @Test("bookmark, mark-passage, and flashcard commands are forwarded")
    func studyCaptureCommandsForwardPayloads() {
        let facade = FakeWatchCommandFacade()
        let router = WatchCommandRouter(facade: facade)

        _ = self.reply(from: router, message: ["command": "addBookmark"])
        _ = self.reply(from: router, message: ["command": "markPassage"])
        _ = self.reply(from: router, message: [
            "command": "addWatchTextBookmark",
            "bookmarkStorageKey": "book-1",
            "trackId": "track-1",
            "timestamp": 42.0
        ])
        _ = self.reply(from: router, message: [
            "command": "gradeFlashcard",
            "cardID": "card-1",
            "grade": 4
        ])

        #expect(facade.calls.contains("addBookmarkFromWatchCommand"))
        #expect(facade.calls.contains("markPassageFromWatchCommand"))
        #expect(facade.addedWatchBookmarkPayloads.count == 1)
        #expect(facade.addedWatchBookmarkPayloads.first?["bookmarkStorageKey"] as? String == "book-1")
        #expect(facade.gradedFlashcards.count == 1)
        #expect(facade.gradedFlashcards.first?.cardID == "card-1")
        #expect(facade.gradedFlashcards.first?.grade == 4)
    }

    @Test("queued (background) channel drops stale transport and navigation commands")
    func queuedChannelIgnoresTimeSensitiveCommands() {
        let facade = FakeWatchCommandFacade()
        let router = WatchCommandRouter(facade: facade)

        // These arrive via WCSession.transferUserInfo, a persistent FIFO queue that
        // can drain minutes later (even on the next launch). By then the intent is
        // stale, so the router must drop them rather than replay them on the player.
        let staleCommands = [
            "play", "pause", "toggle",
            "next", "previous", "nextSection", "previousSection",
            "skipForward", "skipBackward",
            "seek", "scrubDelta", "volumeDelta",
            "cycleSpeed", "cycleLoopMode",
            "setSleepTimer", "cancelSleepTimer", "toggleSleepTimer",
            "markPassage"
        ]
        for command in staleCommands {
            router.route(queuedMessage: ["command": command])
        }

        #expect(facade.calls.isEmpty)
    }

    @Test("queued (background) channel still delivers bookmarks and flashcard grades")
    func queuedChannelDeliversDeferredSafeCommands() {
        let facade = FakeWatchCommandFacade()
        let router = WatchCommandRouter(facade: facade)

        router.route(queuedMessage: ["command": "addBookmark"])
        router.route(queuedMessage: [
            "command": "addWatchTextBookmark",
            "bookmarkStorageKey": "book-1"
        ])
        router.route(queuedMessage: [
            "command": "gradeFlashcard",
            "cardID": "card-9",
            "grade": 3
        ])

        #expect(facade.calls.contains("addBookmarkFromWatchCommand"))
        #expect(facade.calls.contains("addWatchBookmark"))
        #expect(facade.calls.contains("gradeFlashcard"))
    }

    private func reply(
        from router: WatchCommandRouter,
        message: [String: Any]
    ) -> [String: Any] {
        var result: [String: Any] = [:]
        router.route(message: message) { reply in
            result = reply
        }
        return result
    }
}

@MainActor
private final class FakeWatchCommandFacade: WatchCommandRoutingFacade {
    var calls: [String] = []
    var currentPlaybackTime: TimeInterval = 0
    var durationSeconds: Double?
    var speed: Float = 1.0
    var watchCommandOutputGain: Float = 0
    var watchThumbnailData: Data? = Data([0x01, 0x02, 0x03])
    var crownScrubSensitivity: Double = 1
    var crownVolumeSensitivity: Double = 1
    var navigationShouldBookmarkJump = false
    var seekSeconds: [Double] = []
    var seekFractions: [Double] = []
    var appliedGains: [Float] = []
    var setSpeeds: [Float] = []
    var sleepModes: [SleepTimerMode] = []
    var toggleSleepTimerCalled = false
    var addedWatchBookmarkPayloads: [[String: Any]] = []
    var gradedFlashcards: [(cardID: String, grade: Int)] = []

    func play() { calls.append("play") }
    func pause() { calls.append("pause") }
    func togglePlayPause() { calls.append("togglePlayPause") }

    func skipBackwardNavigation() -> Bool {
        calls.append("skipBackwardNavigation")
        return navigationShouldBookmarkJump
    }

    func skipForwardNavigation() -> Bool {
        calls.append("skipForwardNavigation")
        return navigationShouldBookmarkJump
    }

    func nextSection() {
        calls.append("nextSection")
    }

    func previousSectionOrRestart() {
        calls.append("previousSectionOrRestart")
    }

    func skipBackward30() -> Bool {
        calls.append("skipBackward30")
        return navigationShouldBookmarkJump
    }

    func skipForward30() -> Bool {
        calls.append("skipForward30")
        return navigationShouldBookmarkJump
    }

    func seek(toSeconds targetSeconds: Double) {
        calls.append("seekToSeconds")
        seekSeconds.append(targetSeconds)
    }

    func seek(toFraction fraction: Double) {
        calls.append("seekToFraction")
        seekFractions.append(fraction)
    }

    func setSpeed(_ newSpeed: Float) {
        calls.append("setSpeed")
        speed = newSpeed
        setSpeeds.append(newSpeed)
    }

    func setWatchCommandOutputGain(_ gain: Float) {
        calls.append("setWatchCommandOutputGain")
        watchCommandOutputGain = gain
        appliedGains.append(gain)
    }

    func cycleLoopMode() { calls.append("cycleLoopMode") }

    func setSleepTimer(_ mode: SleepTimerMode) {
        calls.append("setSleepTimer")
        sleepModes.append(mode)
    }

    func cancelSleepTimer() { calls.append("cancelSleepTimer") }

    func toggleSleepTimer() {
        calls.append("toggleSleepTimer")
        toggleSleepTimerCalled = true
    }

    func addBookmarkFromWatchCommand() { calls.append("addBookmarkFromWatchCommand") }

    func addWatchBookmark(from payload: [String: Any]) {
        calls.append("addWatchBookmark")
        addedWatchBookmarkPayloads.append(payload)
    }

    func markPassageFromWatchCommand() {
        calls.append("markPassageFromWatchCommand")
    }

    func gradeFlashcard(cardID: String, grade: Int) {
        calls.append("gradeFlashcard")
        gradedFlashcards.append((cardID, grade))
    }

    func watchStateContext() -> [String: Any] {
        [
            "title": "Test Book",
            "isPlaying": false
        ]
    }
}
