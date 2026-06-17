// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// Structural tests: the macOS skip controls must read `player.skipInterval`
/// rather than a hardcoded ±15 literal, so the player bar and the Playback
/// menu can never drift from the user's configured interval. The `Echo macOS`
/// target is not compiled into EchoTests, so we scan source text.
struct MacSkipIntervalWiringTests {

    @Test func playerModelDeclaresSkipInterval() throws {
        let src = try MacSource.read("Views/MacPlayerModel.swift")
        #expect(
            src.contains("var skipInterval: Int = 15"),
            "MacPlayerModel must own a configurable skipInterval (default 15).")
    }

    @Test func triPaneSkipButtonsUseSkipInterval() throws {
        let src = try MacSource.read("Views/MacTriPaneView.swift")
        #expect(
            src.contains("player.skip(by: -Double(player.skipInterval))"),
            "Back-skip button must use the configured interval.")
        #expect(
            src.contains("player.skip(by: Double(player.skipInterval))"),
            "Forward-skip button must use the configured interval.")
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
            src.contains("player.skip(by: -Double(player.skipInterval))"),
            "Skip-back menu command must use the configured interval.")
        #expect(
            src.contains("player.skip(by: Double(player.skipInterval))"),
            "Skip-forward menu command must use the configured interval.")
        #expect(
            src.contains("player.skip(by: -30)") && src.contains("player.skip(by: 30)"),
            "The ⌘⌥ long-skip commands stay at a fixed 30s.")
    }
}
