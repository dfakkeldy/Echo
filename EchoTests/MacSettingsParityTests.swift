// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// Structural tests for macOS Settings parity additions in MacSettingsView. The
/// `Echo macOS` target is not compiled into EchoTests, so we assert against
/// source text via `MacSource`. Only settings that macOS actually consumes are
/// exposed (avoiding the "settings that lie" anti-pattern).
struct MacSettingsParityTests {

    @Test func smartRewindExposesThresholds() throws {
        let src = try MacSource.read("Views/MacSettingsView.swift")
        #expect(
            src.contains("$settings.rewindPauseSecondsThreshold"),
            "Smart Rewind settings must expose the short-pause threshold (playback already reads it)."
        )
        #expect(
            src.contains("$settings.rewindAmountAfterMinutes"),
            "Smart Rewind settings must expose the per-tier rewind amounts.")
        #expect(
            src.contains("$settings.rewindHoursToChapterStart"),
            "Smart Rewind settings must expose the hours-level jump-to-chapter-start toggle.")
    }

    @Test func aboutSectionShowsVersionAndCommit() throws {
        let src = try MacSource.read("Views/MacSettingsView.swift")
        #expect(
            src.contains("buildMetadata.versionString"),
            "Support pane must show the app version.")
        #expect(
            src.contains("buildMetadata.commitString"),
            "Support pane must show the build commit hash (with copy).")
    }
}
