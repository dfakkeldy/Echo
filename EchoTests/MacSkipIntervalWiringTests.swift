// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// Structural tests: the macOS skip controls must route through the player's
/// configured forward/backward skip seams rather than hardcoded ±15 literals, so
/// the player bar and the Playback menu can never drift from user settings. The
/// `Echo macOS` target is not compiled into EchoTests, so we scan source text.
struct MacSkipIntervalWiringTests {

    @Test func playerModelDeclaresSkipInterval() throws {
        let src = try MacSource.read("Views/MacPlayerModel.swift")
        #expect(
            src.contains("var skipInterval: Int = 15"),
            "MacPlayerModel must own a configurable forward skip interval.")
        #expect(
            src.contains("var skipBackInterval: Int = 15"),
            "MacPlayerModel must own a configurable backward skip interval.")
        #expect(
            src.contains("func skipForward()")
                && src.contains("skip(by: Double(skipInterval))"),
            "Forward transport skip must use the configured forward interval.")
        #expect(
            src.contains("func skipBackward()")
                && src.contains("currentTime - Double(skipBackInterval)"),
            "Backward transport skip must use the configured backward interval.")
    }

    @Test func triPaneSkipButtonsUseSkipInterval() throws {
        let src = try MacSource.read("Views/MacTriPaneView.swift")
        #expect(
            src.contains("player.skipBackward()"),
            "Back-skip button must route through the configured backward interval.")
        #expect(
            src.contains("player.skipForward()"),
            "Forward-skip button must route through the configured forward interval.")
        #expect(
            !src.contains("player.skip(by: -15)"),
            "Back-skip must not hardcode -15.")
        #expect(
            !src.contains("player.skip(by: 15)"),
            "Forward-skip must not hardcode 15.")
    }

    @Test func menuSkipCommandsUseSkipInterval() throws {
        let src = try MacSource.read("Echo_macOSApp.swift")
        #expect(
            src.contains("player.skipBackward()"),
            "Skip-back menu command must route through the configured backward interval.")
        #expect(
            src.contains("player.skipForward()"),
            "Skip-forward menu command must route through the configured forward interval.")
        #expect(
            src.contains("player.skip(by: -30)") && src.contains("player.skip(by: 30)"),
            "The ⌘⌥ long-skip commands stay at a fixed 30s.")
    }
}
