// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS) || os(macOS)
import AVFoundation
import Foundation
import Testing

@testable import Echo

@MainActor
@Suite(.serialized)
struct AudioEngineCompletionTests {
    @Test func stoppedNodeRetainsPositionAndResumesScheduledSignal() async throws {
        let f = try CompletionAudioFixture()
        defer { f.close() }
        f.audio.playImmediately(atRate: 1)
        _ = try await f.render(frames: 24_000)
        f.audio.pause()
        let position = f.audio.currentTime
        f.audio.play()
        f.node.stop()
        await f.settle()
        f.audio.pause()
        #expect(f.probe.ends == 0)
        #expect(abs(f.audio.currentTime - position) < 0.03)
        f.audio.play()
        #expect(try await f.render(frames: 2_048) > 0.01)
        #expect(f.audio.isPlaying)
    }

    @Test func stoppedEngineResumesSignalAtRetainedPosition() async throws {
        let f = try CompletionAudioFixture()
        defer { f.close() }
        f.audio.playImmediately(atRate: 1)
        _ = try await f.render(frames: 24_000)
        f.audio.pause()
        let position = f.audio.currentTime
        f.audio.play()
        f.engine.stop()
        await f.settle()
        f.audio.pause()
        #expect(f.probe.ends == 0)
        #expect(abs(f.audio.currentTime - position) < 0.03)
        f.audio.playImmediately(atRate: 1)
        #expect(try await f.render(frames: 2_048) > 0.01)
    }

    @Test(arguments: [false, true])
    func resetThenImmediateStartReschedulesBeforeDelayedCallbacks(stopEngine: Bool) async throws {
        let f = try CompletionAudioFixture()
        defer { f.close() }
        f.audio.playImmediately(atRate: 1)
        _ = try await f.render(frames: 24_000)
        f.audio.pause()
        let position = f.audio.currentTime
        f.audio.play()
        if stopEngine { f.engine.stop() } else { f.node.stop() }
        // No actor hop or explicit pause: own isPlaying may still be stale-true.
        f.audio.playImmediately(atRate: 1)
        #expect(abs(f.audio.currentTime - position) < 0.03)
        #expect(try await f.render(frames: 2_048) > 0.01)
        await f.settle()
        #expect(f.probe.ends == 0)
    }

    @Test func ordinaryPauseAndResumeKeepPositionAndSignal() async throws {
        let f = try CompletionAudioFixture()
        defer { f.close() }
        f.audio.playImmediately(atRate: 1)
        _ = try await f.render(frames: 24_000)
        f.audio.pause()
        let position = f.audio.currentTime
        #expect(position > 0.9 && position < 1.1)
        await f.settle()
        #expect(f.audio.currentTime == position)
        f.audio.play()
        #expect(try await f.render(frames: 2_048) > 0.01)
        #expect(f.probe.ends == 0)
    }

    @Test func activeRateChangesDoNotReschedulePlayback() async throws {
        let f = try CompletionAudioFixture()
        defer { f.close() }
        f.audio.playImmediately(atRate: 1)
        _ = try await f.render(frames: 24_000)
        let sampleTime = f.node.playerTime(forNodeTime: try #require(f.node.lastRenderTime))?.sampleTime
        f.audio.playImmediately(atRate: 1.25)
        let after = f.node.playerTime(forNodeTime: try #require(f.node.lastRenderTime))?.sampleTime
        #expect(after == sampleTime)
        #expect(try await f.render(frames: 2_048) > 0.01)
        #expect(f.probe.ends == 0)
    }

    @Test func seekAndReplacementSuppressCancelledCompletions() async throws {
        let f = try CompletionAudioFixture()
        defer { f.close() }
        f.audio.playImmediately(atRate: 1)
        _ = try await f.render(frames: 12_000)
        var seekSucceeded = false
        f.audio.seek(to: 2) { seekSucceeded = $0 }
        #expect(seekSucceeded)
        await f.settle()
        #expect(f.audio.currentTime == 2)
        #expect(f.probe.ends == 0)
        try f.audio.replaceCurrentItem(with: f.url, startTime: 1.5).get()
        await f.settle()
        #expect(f.audio.currentTime == 1.5)
        #expect(try await f.render(frames: 2_048) > 0.01)
        #expect(f.probe.ends == 0)
    }

    @Test func stopThenReloadDoesNotCompleteTheNewItem() async throws {
        let f = try CompletionAudioFixture()
        defer { f.close() }
        f.audio.playImmediately(atRate: 1)
        _ = try await f.render(frames: 12_000)
        f.audio.stop()
        try f.audio.replaceCurrentItem(with: f.url, startTime: 1).get()
        f.audio.playImmediately(atRate: 1)
        await f.settle()
        #expect(f.probe.ends == 0)
        #expect(f.audio.currentTime == 1)
        #expect(try await f.render(frames: 2_048) > 0.01)
    }

    @Test func pausedConfigurationChangeDoesNotLoseResumeAudio() async throws {
        let f = try CompletionAudioFixture()
        defer { f.close() }
        f.audio.playImmediately(atRate: 1)
        _ = try await f.render(frames: 24_000)
        f.audio.pause()
        let position = f.audio.currentTime
        f.node.stop()
        f.audio.handleConfigurationChange()
        f.audio.play()
        #expect(abs(f.audio.currentTime - position) < 0.03)
        #expect(try await f.render(frames: 2_048) > 0.01)
        #expect(f.probe.ends == 0)
    }

    @Test func playingConfigurationChangeReschedulesWithoutFalseEnd() async throws {
        let f = try CompletionAudioFixture()
        defer { f.close() }
        f.audio.playImmediately(atRate: 1)
        _ = try await f.render(frames: 24_000)
        f.audio.pause()
        let position = f.audio.currentTime
        f.audio.play()
        f.engine.stop()
        f.audio.handleConfigurationChange()
        await f.settle()
        // On iOS a built-in output route correctly pauses instead of leaking sound;
        // the next user resume must nevertheless have audio scheduled.
        if !f.audio.isPlaying { f.audio.play() }
        #expect(abs(f.audio.currentTime - position) < 0.03)
        #expect(try await f.render(frames: 2_048) > 0.01)
        #expect(f.probe.ends == 0)
    }

    @Test func stopDetectionBeforeConfigurationNotificationStillRecovers() async throws {
        let f = try CompletionAudioFixture()
        defer { f.close() }
        f.audio.playImmediately(atRate: 1)
        _ = try await f.render(frames: 24_000)
        f.audio.pause()
        let position = f.audio.currentTime
        f.audio.play()
        f.engine.stop()
        // Same stop-detection handler as the completion/timer, before the later notification.
        f.audio.handleStoppedPlayback()
        #if os(macOS)
        #expect(f.audio.isPlaying)
        #expect(f.engine.isRunning)
        #endif
        f.audio.handleConfigurationChange()
        if !f.audio.isPlaying { f.audio.play() }
        #expect(abs(f.audio.currentTime - position) < 0.03)
        #expect(try await f.render(frames: 2_048) > 0.01)
        #expect(f.probe.ends == 0)
    }

    @Test func genuineDeviceRenderedCompletionHappensOnce() async throws {
        // dataPlayedBack applies to device rendering, not manual/offline rendering.
        // This graph's node volume is zero; no global output setting is changed.
        let f = try CompletionAudioFixture(seconds: 0.25, offline: false)
        defer { f.close() }
        f.audio.playImmediately(atRate: 1)
        try await f.waitForEnd()
        #expect(f.probe.ends == 1)
        #expect(f.audio.currentTime == f.audio.duration)
        #expect(!f.audio.isPlaying)
        f.audio.play()
        #expect(!f.audio.isPlaying) // EOF has no playable frames; don't publish silent playback.
    }

    @Test func exactEofSelectsShortFinalChapter() async throws {
        let f = try CompletionAudioFixture(seconds: 0.25, offline: false)
        defer { f.close() }
        let state = PlaybackState()
        state.chapters = [
            Chapter(index: 0, title: "First", startSeconds: 0, endSeconds: 0.2),
            Chapter(index: 1, title: "Final", startSeconds: 0.2, endSeconds: 0.25),
        ]
        state.currentChapterIndex = 0
        let coordinator = ChapterLoadingCoordinator()
        coordinator.state = state
        coordinator.audioEngine = f.audio
        f.audio.playImmediately(atRate: 1)
        try await f.waitForEnd()
        coordinator.updateCurrentChapterFromPlayerTime()
        #expect(state.currentChapterIndex == 1)
        #expect(state.currentSubtitle == "Final")
    }

    @Test func eofProgressRefreshRecalculatesChapterWithinBoundaryTolerance() async throws {
        let f = try CompletionAudioFixture(seconds: 0.25, offline: false)
        defer { f.close() }
        let state = PlaybackState()
        state.tracks = [Track(url: f.url, title: "Synthetic")]
        state.durationSeconds = 0.25
        state.chapters = [
            Chapter(index: 0, title: "First", startSeconds: 0, endSeconds: 0.2),
            Chapter(index: 1, title: "Final", startSeconds: 0.2, endSeconds: 0.25),
        ]
        state.currentChapterIndex = 0
        let coordinator = ChapterLoadingCoordinator()
        coordinator.state = state
        coordinator.audioEngine = f.audio
        let presenter = PlaybackProgressPresenter()
        presenter.state = state
        presenter.audioEngine = f.audio
        presenter.speedProvider = { 1 }
        presenter.onChapterOutOfBounds = { coordinator.updateCurrentChapterFromPlayerTime() }
        f.audio.playImmediately(atRate: 1)
        try await f.waitForEnd()
        // This is the narrow coordinator_refreshProgress path used before end decisions.
        presenter.updateProgress()
        #expect(state.currentChapterIndex == 1)
        #expect(state.currentSubtitle == "Final")
        #expect(state.progressFraction == 1)
        #expect(state.bookProgressPercent == 100)
    }

    @Test func completionRefreshesProgressBeforeSleepOrCheckpointHandling() throws {
        let f = try CompletionAudioFixture()
        defer { f.close() }
        let c = PlaybackController(audioEngine: f.audio)
        var events: [String] = []
        c.coordinator_refreshProgress = { events.append("refresh") }
        let receiver = CompletionControllerProbe { events.append("end") }
        c.delegate = receiver
        c.audioEngineDidPlayToEnd(f.audio)
        #expect(events == ["refresh", "end"])
    }

    #if os(iOS)
    @Test func interruptionThenResumeRetainsPlayablePosition() async throws {
        let f = try CompletionAudioFixture()
        defer { f.close() }
        f.audio.playImmediately(atRate: 1)
        _ = try await f.render(frames: 24_000)
        f.audio.pause()
        let position = f.audio.currentTime
        f.audio.play()
        // Call the same owned handler used by the notification observer rather
        // than broadcasting a synthetic interruption to other concurrent suites.
        f.audio.handleInterruptionBegan()
        await f.settle()
        #expect(!f.audio.isPlaying)
        f.node.stop()
        f.audio.play()
        #expect(abs(f.audio.currentTime - position) < 0.03)
        #expect(try await f.render(frames: 2_048) > 0.01)
        #expect(f.probe.ends == 0)
    }
    #endif
}

@MainActor
private final class CompletionAudioFixture {
    let url: URL
    let engine = AVAudioEngine()
    let node = AVAudioPlayerNode()
    let audio: AudioEngine
    let probe = CompletionEngineProbe()

    init(seconds: Double = 4, offline: Bool = true) throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("completion-\(UUID().uuidString).caf")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 24_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * 24_000)))
        buffer.frameLength = buffer.frameCapacity
        let channel = try #require(buffer.floatChannelData?[0])
        for i in 0..<Int(buffer.frameLength) { channel[i] = 0.1 }
        let writer = try AVAudioFile(forWriting: url, settings: format.settings)
        try writer.write(from: buffer)
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        if offline { try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512) }
        else { node.volume = 0 }
        audio = AudioEngine(engine: engine, playerNode: node)
        audio.delegate = probe
        try audio.replaceCurrentItem(with: url).get()
    }

    func render(frames: Int) async throws -> Float {
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 512))
        var remaining = frames
        var peak: Float = 0
        while remaining > 0 {
            let count = min(512, remaining)
            let status = try engine.renderOffline(AVAudioFrameCount(count), to: buffer)
            #expect(status == .success)
            if let data = buffer.floatChannelData?[0] {
                for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[i])) }
            }
            remaining -= count
            await Task.yield()
        }
        return peak
    }

    func settle() async { try? await Task.sleep(for: .milliseconds(100)) }

    func waitForEnd() async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while probe.ends == 0, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(probe.ends == 1)
    }

    func close() { audio.delegate = nil; audio.cleanup(); try? FileManager.default.removeItem(at: url) }
}

@MainActor
private final class CompletionEngineProbe: AudioEngineDelegate {
    var ends = 0
    func audioEngineDidPlayToEnd(_ engine: AudioEngine) { ends += 1 }
    func audioEngineDidUpdateTime(_ engine: AudioEngine, currentTime: TimeInterval) {}
    func audioEngineInterruptionBegan(_ engine: AudioEngine) {}
    func audioEngineInterruptionEnded(_ engine: AudioEngine, shouldResume: Bool) {}
    func audioEngineOutputDeviceDisconnected(_ engine: AudioEngine) {}
    func audioEngineDidStopUnexpectedly(_ engine: AudioEngine) {}
}

@MainActor
private final class CompletionControllerProbe: PlaybackControllerDelegate {
    let onEnd: () -> Void
    init(_ onEnd: @escaping () -> Void) { self.onEnd = onEnd }
    func playbackControllerDidPlayToEnd(_ controller: PlaybackController) { onEnd() }
    func playbackController(_ controller: PlaybackController, didUpdateTime currentTime: TimeInterval) {}
    func playbackControllerInterruptionBegan(_ controller: PlaybackController) {}
    func playbackControllerInterruptionEnded(_ controller: PlaybackController, shouldResume: Bool) {}
}
#endif
