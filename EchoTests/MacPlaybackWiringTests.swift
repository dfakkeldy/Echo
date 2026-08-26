// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// Structural tests locking the macOS loop + volume-boost wiring in
/// MacPlayerModel / MacAudioBoostTap. The `Echo macOS` target is not compiled
/// into EchoTests, so we assert against source text via `MacSource`.
struct MacPlaybackWiringTests {

    @Test func modelDeclaresLoopMode() throws {
        let src = try MacSource.read("Views/MacPlayerModel.swift")
        #expect(
            src.contains("var loopMode: LoopMode = .off"),
            "MacPlayerModel must own a LoopMode (default .off).")
    }

    @Test func timeObserverCallsBoundaryHandler() throws {
        let src = try MacSource.read("Views/MacPlayerModel.swift")
        #expect(
            src.contains("self.handleChapterBoundary()"),
            "The periodic time observer must call handleChapterBoundary().")
        #expect(
            src.contains("MacChapterLoopDecision.evaluate("),
            "handleChapterBoundary must delegate to the pure decision struct.")
        #expect(
            src.contains("sleepTimer.evaluateAtChapterEnd()"),
            "End-of-chapter sleep must fire at the chapter boundary on macOS.")
    }

    @Test func modelDeclaresBoostStateAndAppliesOnOpen() throws {
        let src = try MacSource.read("Views/MacPlayerModel.swift")
        #expect(
            src.contains("var isVolumeBoostEnabled: Bool"),
            "MacPlayerModel must own isVolumeBoostEnabled.")
        #expect(
            src.contains("var volumeBoostGain: Float = 9.0"),
            "MacPlayerModel must own volumeBoostGain (default 9 dB).")
        #expect(
            src.contains("applyVolumeBoost()"),
            "Boost must be (re)applied — including from open(url:).")
        #expect(
            src.contains("\"global_volumeBoostEnabled\""),
            "macOS boost must persist under the same key as iOS.")
    }

    @Test func timeObserverEnforcesBookmarkLoop() throws {
        let src = try MacSource.read("Views/MacPlayerModel.swift")
        #expect(
            src.contains("self.handleBookmarkLoop()"),
            "The periodic time observer must call handleBookmarkLoop().")
        #expect(
            src.contains("MacBookmarkLoopDecision.seekBackTarget("),
            "handleBookmarkLoop must delegate to the pure A–B decision helper.")
        #expect(
            src.contains("guard loopMode == .bookmark else { return }"),
            "handleBookmarkLoop must no-op unless the bookmark loop is active.")
    }

    @Test func popoverDemotesBookmarkLoopWhenUnavailable() throws {
        let src = try MacSource.read("Views/MacPlaybackOptionsSheet.swift")
        #expect(
            src.contains("!player.canBookmarkLoop"),
            "The loop picker must demote .bookmark to .off when bookmark looping is unavailable.")
        #expect(
            src.contains("selection: loopSelection"),
            "The loop picker must route through the demotion binding, not bind loopMode directly.")
        #expect(
            src.contains(".disabled(bookmarkLoopUnavailable)"),
            "The Bookmark segment must be disabled while bookmark looping is unavailable.")
    }

    @Test func tapInstallerExists() throws {
        let src = try MacSource.read("Services/MacAudioBoostTap.swift")
        #expect(
            src.contains("MTAudioProcessingTapCreate"),
            "Boost must use an MTAudioProcessingTap for above-unity gain.")
        #expect(
            src.contains(
            "func makeAudioMix(for item: AVPlayerItem, gainBox: MacVolumeBoostGainBox)"),
            "makeAudioMix signature must match the model's call site.")
    }

    @Test func macPlaybackResumeIsPersistedAndRestored() throws {
        let src = try MacSource.read("Views/MacPlayerModel.swift")
        #expect(
            src.contains("MacPlaybackResumeState.storageKey"),
            "MacPlayerModel must use the shared macOS resume-state storage key.")
        #expect(
            src.contains("persistResumeStateThrottled()"),
            "The periodic time observer must persist resume progress while playback advances.")
        #expect(
            src.contains("persistResumeState()"),
            "Pause/stop/deinit must flush resume progress before teardown.")
        #expect(
            src.contains("matchingTrackIndex("),
            "Folder and narrated-book reopen must restore the saved track, not only track 0.")
        #expect(
            src.contains("restoreResumePositionIfNeeded()"),
            "Opening a track must seek to the saved position when the resume state matches.")
    }
}
