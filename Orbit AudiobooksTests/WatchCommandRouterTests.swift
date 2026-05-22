import Foundation
import Testing
@testable import Orbit_Audiobooks

@MainActor
struct WatchCommandRouterTests {
    @Test("navigation commands forward through facade and include bookmark jump reply")
    func navigationCommandReplyIncludesBookmarkJumpAndThumbnail() async {
        let facade = FakeWatchCommandFacade()
        facade.navigationShouldBookmarkJump = true
        let router = WatchCommandRouter(facade: facade)

        let reply = await reply(from: router, message: ["command": "next"])

        #expect(facade.calls == ["skipForwardNavigation"])
        #expect(reply["commandResult"] as? String == "bookmarkJump")
        #expect(reply["thumbnailData"] as? Data == Data([0x01, 0x02, 0x03]))
        #expect(reply["title"] as? String == "Test Book")
    }

    @Test("scrub and volume deltas clamp through facade settings")
    func deltasUseFacadeSettingsAndClampOutputs() async {
        let facade = FakeWatchCommandFacade()
        facade.currentPlaybackTime = 190
        facade.durationSeconds = 200
        facade.watchCommandOutputGain = 8
        facade.crownScrubSensitivity = 1
        facade.crownVolumeSensitivity = 1
        let router = WatchCommandRouter(facade: facade)

        _ = await reply(from: router, message: ["command": "scrubDelta", "delta": 1.0])
        _ = await reply(from: router, message: ["command": "volumeDelta", "delta": 1.0])

        #expect(facade.seekSeconds == [200])
        #expect(facade.appliedGains == [9])
    }

    @Test("non-positive crown sensitivities fall back to defaults")
    func deltasUseDefaultSensitivityFallbacks() async {
        let facade = FakeWatchCommandFacade()
        facade.currentPlaybackTime = 100
        facade.durationSeconds = 200
        facade.crownScrubSensitivity = 0
        facade.crownVolumeSensitivity = 0
        let router = WatchCommandRouter(facade: facade)

        _ = await reply(from: router, message: ["command": "scrubDelta", "delta": 1.0])
        _ = await reply(from: router, message: ["command": "volumeDelta", "delta": 1.0])

        #expect(facade.seekSeconds == [115])
        #expect(abs((facade.appliedGains.last ?? -1) - 0.3) < 0.001)
    }

    @Test("speed and sleep timer commands map to facade operations")
    func speedAndSleepTimerCommandsMapToFacade() async {
        let facade = FakeWatchCommandFacade()
        facade.speed = 1.5
        let router = WatchCommandRouter(facade: facade)

        _ = await reply(from: router, message: ["command": "cycleSpeed"])
        _ = await reply(from: router, message: ["command": "cycleSpeed", "playbackSpeed": 1.75])
        _ = await reply(from: router, message: [
            "command": "setSleepTimer",
            "sleepTimerMode": "minutes",
            "sleepTimerMinutes": 25
        ])
        _ = await reply(from: router, message: [
            "command": "setSleepTimer",
            "sleepTimerMode": "endOfChapter"
        ])
        _ = await reply(from: router, message: ["command": "cancelSleepTimer"])

        #expect(facade.setSpeeds == [2.0, 1.75])
        #expect(facade.sleepModes == [.minutes(25), .endOfChapter])
        #expect(facade.calls.contains("cancelSleepTimer"))
    }

    @Test("bookmark and flashcard commands are forwarded without changing payloads")
    func bookmarkAndFlashcardCommandsForwardPayloads() async {
        let facade = FakeWatchCommandFacade()
        let router = WatchCommandRouter(facade: facade)

        _ = await reply(from: router, message: ["command": "addBookmark"])
        _ = await reply(from: router, message: [
            "command": "addWatchTextBookmark",
            "bookmarkStorageKey": "book-1",
            "trackId": "track-1",
            "timestamp": 42.0
        ])
        _ = await reply(from: router, message: [
            "command": "gradeFlashcard",
            "cardID": "card-1",
            "grade": 4
        ])

        #expect(facade.calls.contains("addBookmarkFromWatchCommand"))
        #expect(facade.addedWatchBookmarkPayloads.count == 1)
        #expect(facade.addedWatchBookmarkPayloads.first?["bookmarkStorageKey"] as? String == "book-1")
        #expect(facade.gradedFlashcards.count == 1)
        #expect(facade.gradedFlashcards.first?.cardID == "card-1")
        #expect(facade.gradedFlashcards.first?.grade == 4)
    }

    private func reply(
        from router: WatchCommandRouter,
        message: [String: Any]
    ) async -> [String: Any] {
        await withCheckedContinuation { continuation in
            router.route(message: message) { reply in
                continuation.resume(returning: reply)
            }
        }
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
    func addBookmarkFromWatchCommand() { calls.append("addBookmarkFromWatchCommand") }

    func addWatchBookmark(from payload: [String: Any]) {
        calls.append("addWatchBookmark")
        addedWatchBookmarkPayloads.append(payload)
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
