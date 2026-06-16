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
}
