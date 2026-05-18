import Foundation
@testable import Orbit_Audiobooks

/// Configurable PlaybackController for unit testing.
final class MockPlaybackController: PlaybackControllerProtocol {
    var isPlaying: Bool = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval? = 300
    var speed: Float = 1.0

    var playCallCount = 0
    var pauseCallCount = 0
    var togglePlayPauseCallCount = 0
    var skipForward30CallCount = 0
    var skipBackward30CallCount = 0
    var seekCalls: [TimeInterval] = []
    var nextChapterCallCount = 0
    var previousChapterOrRestartCallCount = 0

    func play() {
        isPlaying = true
        playCallCount += 1
    }

    func pause() {
        isPlaying = false
        pauseCallCount += 1
    }

    func togglePlayPause() {
        isPlaying.toggle()
        togglePlayPauseCallCount += 1
    }

    func skipForward30() -> Bool {
        currentTime += 30
        skipForward30CallCount += 1
        return true
    }

    func skipBackward30() -> Bool {
        currentTime = max(0, currentTime - 30)
        skipBackward30CallCount += 1
        return true
    }

    func seek(to time: TimeInterval) {
        currentTime = time
        seekCalls.append(time)
    }

    func nextChapter() {
        nextChapterCallCount += 1
    }

    func previousChapterOrRestart() {
        previousChapterOrRestartCallCount += 1
    }
}
