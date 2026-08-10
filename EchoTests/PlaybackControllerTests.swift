// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
@Suite struct PlaybackControllerTests {

    /// Any pause — user, remote/lock-screen, audio-session interruption,
    /// output-route disconnect, sleep timer — must cancel a pending narration
    /// at-gap auto-resume so the render loop does not fight the user.
    @Test func pauseClearsAwaitingNarrationChapter() {
        let c = PlaybackController()
        c.state.awaitingNarrationChapter = true

        c.pause()

        #expect(c.state.awaitingNarrationChapter == false)
    }

    /// Regression guard for the reorder footgun: the narration gap branch in
    /// nextTrack() must set awaitingNarrationChapter AFTER calling pause()
    /// (because pause() now clears it). If someone reverts to set-before-pause,
    /// the flag is wiped by pause() and this test's awaiting==true assertion
    /// fails — and on-device playback would stall forever at the gap.
    @Test func gapBranchSetsFlagAfterPause() {
        let c = PlaybackController()
        // Single-track narration queue at the last index so:
        //   - chapters.count < 2 skips nextChapter()
        //   - findNextEnabledTrackIndex returns nil (no enabled track after idx 0)
        //   - narrationRenderInFlight == true takes the gap branch (not the
        //     firstEnabled fallback, which is only reached when the flag is false)
        c.state.tracks = [Track(url: URL(string: "file:///tmp/ch0.m4a")!, title: "Chapter 1")]
        c.state.currentIndex = 0
        c.state.chapters = []
        c.state.narrationRenderInFlight = true

        c.nextTrack()

        // Flag survived pause() (set-AFTER-pause ordering intact)...
        #expect(c.state.awaitingNarrationChapter == true)
        // ...and the gap path did pause playback.
        #expect(c.state.isPlaying == false)
    }

    @Test func ordinaryPauseAndNarrationGapEmitDifferentChanges() {
        let ordinary = PlaybackController()
        var ordinaryChanges: [PlaybackActivityChange] = []
        ordinary.coordinator_playStateChanged = { ordinaryChanges.append($0) }
        ordinary.pause()
        #expect(ordinaryChanges.last == .paused)

        let gap = PlaybackController()
        var gapChanges: [PlaybackActivityChange] = []
        gap.coordinator_playStateChanged = { gapChanges.append($0) }
        gap.state.tracks = [
            Track(url: URL(fileURLWithPath: "/tmp/ch0.m4a"), title: "Chapter 1")
        ]
        gap.state.currentIndex = 0
        gap.state.narrationRenderInFlight = true
        gap.nextTrack()
        #expect(gapChanges.last == .waitingForNarration)
        #expect(gap.state.awaitingNarrationChapter)
    }

    @Test func playDoesNotPublishPlayingWhenTrackLoadingProducesNoItem() {
        let controller = PlaybackController()
        controller.state.tracks = [
            Track(url: URL(fileURLWithPath: "/missing/audio.m4a"), title: "Unavailable")
        ]
        controller.coordinator_configureAudioSession = {}
        controller.coordinator_loadTrack = { _, _ in }
        controller.coordinator_startSecurityScope = {}
        controller.coordinator_persistAndSync = { _ in }
        var changes: [PlaybackActivityChange] = []
        controller.coordinator_playStateChanged = { changes.append($0) }

        controller.play()

        #expect(changes.contains(.playing) == false)
        #expect(controller.state.isPlaying == false)
        #expect(controller.isPlaying == false)
    }

    @Test func naturalEndIsNotEmittedForManualNextAtQueueEnd() {
        let controller = PlaybackController()
        var changes: [PlaybackActivityChange] = []
        controller.coordinator_playStateChanged = { changes.append($0) }
        controller.state.tracks = [
            Track(url: URL(fileURLWithPath: "/tmp/ch0.m4a"), title: "Chapter 1")
        ]
        controller.nextTrack()
        #expect(!changes.contains(.reachedNaturalEnd))
        controller.nextTrack(naturalEnd: true)
        #expect(changes.last == .reachedNaturalEnd)
    }

    @Test func naturalEndIsNotEmittedBeforeNextEmbeddedChapter() {
        let controller = PlaybackController()
        var changes: [PlaybackActivityChange] = []
        controller.coordinator_playStateChanged = { changes.append($0) }
        controller.state.tracks = [
            Track(url: URL(fileURLWithPath: "/tmp/book.m4b"), title: "Book")
        ]
        controller.state.currentIndex = 0
        controller.state.chapters = [
            Chapter(index: 0, title: "One", startSeconds: 0, endSeconds: 10),
            Chapter(index: 1, title: "Two", startSeconds: 10, endSeconds: 20),
        ]
        controller.state.currentChapterIndex = 0

        controller.nextTrack(naturalEnd: true)

        #expect(changes.contains(.reachedNaturalEnd) == false)
    }

    @Test func naturalEndIsNotEmittedBeforeNextAggregatedChapter() {
        let controller = PlaybackController()
        var changes: [PlaybackActivityChange] = []
        controller.coordinator_playStateChanged = { changes.append($0) }
        let firstURL = URL(fileURLWithPath: "/tmp/volume-one.m4b")
        let secondURL = URL(fileURLWithPath: "/tmp/volume-two.m4b")
        let currentChapters = [
            Chapter(index: 0, title: "Two-A", startSeconds: 0, endSeconds: 5),
            Chapter(index: 1, title: "Two-B", startSeconds: 5, endSeconds: 10),
        ]
        controller.state.tracks = [
            Track(url: firstURL, title: "Volume One"),
            Track(url: secondURL, title: "Volume Two"),
        ]
        controller.state.currentIndex = 1
        controller.state.chapters = currentChapters
        controller.state.currentChapterIndex = 0
        controller.state.m4bBooks = [
            M4BBook(
                url: firstURL, title: "Volume One", duration: 10, chapters: [],
                cumulativeStartOffset: 0, trackIndex: 0),
            M4BBook(
                url: secondURL, title: "Volume Two", duration: 10,
                chapters: currentChapters, cumulativeStartOffset: 10, trackIndex: 1),
        ]
        controller.state.aggregatedChapters = [
            AggregatedChapter(
                bookTitle: "Volume One", bookIndex: 0, chapterTitle: "One",
                chapterIndex: 0, startSeconds: 0, endSeconds: 10,
                sourceBookURL: firstURL),
            AggregatedChapter(
                bookTitle: "Volume Two", bookIndex: 1, chapterTitle: "Two-A",
                chapterIndex: 0, startSeconds: 10, endSeconds: 15,
                sourceBookURL: secondURL),
            AggregatedChapter(
                bookTitle: "Volume Two", bookIndex: 1, chapterTitle: "Two-B",
                chapterIndex: 1, startSeconds: 15, endSeconds: 20,
                sourceBookURL: secondURL),
        ]

        controller.nextTrack(naturalEnd: true)

        #expect(changes.contains(.reachedNaturalEnd) == false)
    }

    @Test func endOfBookDoesNotWrapToStart() {
        // Last chapter of a single-track book: nextChapter() must stay put, not
        // auto-restart the book from chapter 0 (§5.2). Previously it fell through
        // to `firstEnabled` and reloaded index 0 with autoplay.
        let c = PlaybackController()
        c.state.tracks = [Track(url: URL(string: "file:///tmp/book.m4b")!, title: "Book")]
        c.state.currentIndex = 0
        c.state.chapters = [
            Chapter(index: 0, title: "One", startSeconds: 0, endSeconds: 10),
            Chapter(index: 1, title: "Two", startSeconds: 10, endSeconds: 20),
        ]
        c.state.currentChapterIndex = 1
        // isMultiM4B is a computed get-only property; a single track with no
        // aggregated chapters is already non-aggregated.
        var loaded: Int?
        c.coordinator_loadTrack = { idx, _ in loaded = idx }

        c.nextChapter()

        #expect(loaded == nil)
    }

    @Test func terminalTrackEndOffersCheckpointBeforeSleepTimer() async throws {
        let c = PlaybackController()
        let audioURL = try await SilentAudioFixture.makeSilentM4A(seconds: 1)
        defer { try? FileManager.default.removeItem(at: audioURL) }
        c.audioEngine.configureAudioSession()
        c.audioEngine.replaceCurrentItem(with: audioURL)
        defer { c.audioEngine.cleanup() }

        c.state.tracks = [Track(url: audioURL, title: "Book")]
        c.state.currentIndex = 0
        c.state.chapters = [
            Chapter(index: 0, title: "One", startSeconds: 0, endSeconds: 1),
            Chapter(index: 1, title: "Two", startSeconds: 1, endSeconds: 2),
        ]
        c.state.currentChapterIndex = 1
        c.loopMode = .off
        var checkpointIndex: Int?
        var didCheckSleepTimer = false
        var loadedIndex: Int?

        c.coordinator_handleChapterEndCheckpoint = { index in
            checkpointIndex = index
            return true
        }
        c.coordinator_handleChapterEndSleepTimer = {
            didCheckSleepTimer = true
            return true
        }
        c.coordinator_loadTrack = { index, _ in
            loadedIndex = index
        }

        c.handleTrackEnded()

        #expect(checkpointIndex == 1)
        #expect(didCheckSleepTimer == false)
        #expect(loadedIndex == nil)
    }

    @Test func lastChapterLoopResumesAfterTerminalTrackEnd() async throws {
        let c = PlaybackController()
        let audioURL = try await SilentAudioFixture.makeSilentM4A(seconds: 3)
        defer { try? FileManager.default.removeItem(at: audioURL) }
        c.audioEngine.configureAudioSession()
        c.audioEngine.replaceCurrentItem(with: audioURL)
        defer { c.audioEngine.cleanup() }

        c.state.tracks = [Track(url: audioURL, title: "Book")]
        c.state.currentIndex = 0
        c.state.chapters = [
            Chapter(index: 0, title: "One", startSeconds: 0, endSeconds: 1.5),
            Chapter(index: 1, title: "Two", startSeconds: 1.5, endSeconds: 3),
        ]
        c.state.currentChapterIndex = 1
        c.loopMode = .chapter
        c.speed = 1.0
        c.state.isPlaying = true

        c.handleTrackEnded()

        #expect(abs(c.audioEngine.currentTime - 1.55) < 0.01)
        #expect(c.audioEngine.isPlaying)
    }

    @Test func findNextEnabledTrackIndexDoesNotTrapPastEnd() {
        let c = PlaybackController()
        let t = Track(url: URL(string: "file:///tmp/a.m4a")!, title: "A")
        // currentIndex past the last valid index must return nil, not trap.
        #expect(c.findNextEnabledTrackIndex(in: [t], currentIndex: 1) == nil)
    }

    @Test func forwardSkipTargetDoesNotCollapseToZeroWhenDurationUnknown() {
        // Unknown duration (briefly nil right after a track load) must not clamp
        // the target to 0 (which seeked to the track start).
        #expect(
            PlaybackController.forwardSkipTarget(current: 120, amount: 30, duration: nil) == 150)
        #expect(
            PlaybackController.forwardSkipTarget(current: 120, amount: 30, duration: 600) == 150)
        #expect(
            PlaybackController.forwardSkipTarget(current: 590, amount: 30, duration: 600) == 600)
    }

    @Test func cycleSkipsBookmarkLoopWhenUnavailable() {
        let c = PlaybackController()
        c.loopMode = .chapter
        c.coordinator_canBookmarkLoop = { false }

        c.cycleLoopMode()

        #expect(c.loopMode == .off)
    }

    @Test func cycleEntersBookmarkLoopWhenAvailable() {
        let c = PlaybackController()
        c.loopMode = .chapter
        c.coordinator_canBookmarkLoop = { true }

        c.cycleLoopMode()

        #expect(c.loopMode == .bookmark)
    }

    @Test func findNextEnabledTrackIndexReturnsNilForOutOfRangeIndex() {
        let c = PlaybackController()
        let tracks = [
            Track(url: URL(fileURLWithPath: "/tmp/first.m4a"), title: "First"),
            Track(url: URL(fileURLWithPath: "/tmp/second.m4a"), title: "Second"),
        ]

        #expect(c.findNextEnabledTrackIndex(in: tracks, currentIndex: tracks.count) == nil)
    }

    @Test func nextTrackAtEndDoesNotWrapToFirstEnabled() {
        let c = PlaybackController()
        c.state.tracks = [
            Track(url: URL(fileURLWithPath: "/tmp/first.m4a"), title: "First"),
            Track(url: URL(fileURLWithPath: "/tmp/second.m4a"), title: "Second"),
        ]
        c.state.currentIndex = 1
        var loadedIndex: Int?
        c.coordinator_loadTrack = { index, _ in loadedIndex = index }

        c.nextTrack()

        #expect(loadedIndex == nil)
    }

    @Test func nextChapterAtEndDoesNotWrapToFirstEnabledTrack() {
        let c = PlaybackController()
        c.state.tracks = [
            Track(url: URL(fileURLWithPath: "/tmp/first.m4a"), title: "First"),
            Track(url: URL(fileURLWithPath: "/tmp/second.m4a"), title: "Second"),
        ]
        c.state.currentIndex = 1
        c.state.currentChapterIndex = 1
        c.state.chapters = [
            Chapter(index: 0, title: "One", startSeconds: 0, endSeconds: 10),
            Chapter(index: 1, title: "Two", startSeconds: 10, endSeconds: 20),
        ]
        var loadedIndex: Int?
        c.coordinator_loadTrack = { index, _ in loadedIndex = index }

        c.nextChapter()

        #expect(loadedIndex == nil)
    }

    @Test func forwardSkipTargetUsesCurrentPositionWhenDurationIsUnknown() {
        let target = PlaybackController.forwardSkipTarget(
            current: 75,
            amount: 30,
            duration: nil
        )

        #expect(target == 105)
    }

    @Test func forwardSkipTargetClampsWhenDurationIsKnown() {
        let target = PlaybackController.forwardSkipTarget(
            current: 75,
            amount: 30,
            duration: 80
        )

        #expect(target == 80)
    }
}
