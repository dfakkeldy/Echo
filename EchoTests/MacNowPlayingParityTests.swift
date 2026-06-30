// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// Structural tests locking the macOS Now Playing / Media Center parity wiring
/// and the previously dead-end "settings that lie" fixes in MacPlayerModel /
/// MacSettingsView. The `Echo macOS` target is not compiled into EchoTests, so we
/// assert against source text via `MacSource`. (Behavioral coverage of the shared
/// NowPlayingController lives in NowPlayingControllerTests, iOS target.)
struct MacNowPlayingParityTests {

    // MARK: Now Playing / remote commands

    @Test func remoteCommandsAreWired() throws {
        let src = try MacSource.read("Views/MacPlayerModel.swift")
        #expect(
            src.contains("nowPlayingController.configureRemoteCommands("),
            "macOS must register MPRemoteCommandCenter handlers so media keys / Control Center drive playback."
        )
        #expect(
            src.contains("configureRemoteCommandsIfNeeded()"),
            "play() must ensure remote commands are configured.")
    }

    @Test func chapterMetadataIsPublished() throws {
        let src = try MacSource.read("Views/MacPlayerModel.swift")
        #expect(
            src.contains("params.chapterIndex = currentChapterIndex"),
            "updateNowPlaying() must publish chapter metadata for Lock-Screen chapter number / timing."
        )
    }

    @Test func elapsedTimeTicks() throws {
        let src = try MacSource.read("Views/MacPlayerModel.swift")
        #expect(
            src.contains("updateNowPlayingElapsed()"),
            "The periodic time observer and seek must push elapsed-time ticks to Now Playing.")
        #expect(
            src.contains("nowPlayingController.updateElapsedTime("),
            "Elapsed ticks must go through NowPlayingController.updateElapsedTime.")
    }

    // MARK: Settings that previously lied

    @Test func backwardSkipUsesItsOwnDuration() throws {
        let src = try MacSource.read("Views/MacPlayerModel.swift")
        #expect(
            src.contains("skipBackInterval = settings.seekBackwardDuration"),
            "Skip-Backward duration must be read from settings (was silently ignored).")
        #expect(
            src.contains("func skipBackward()"),
            "A dedicated backward skip must apply the backward interval with a chapter-start clamp."
        )
    }

    @Test func volumeBoostGainComesFromSettings() throws {
        let src = try MacSource.read("Views/MacPlayerModel.swift")
        #expect(
            src.contains("volumeBoostGain = settings.volumeBoostGain"),
            "Volume-Boost dB must be read from settings (was hardcoded at 9 dB).")
    }

    @Test func smartRewindIsGatedAndConfigured() throws {
        let src = try MacSource.read("Views/MacPlayerModel.swift")
        #expect(
            src.contains("isRewindEnabled"),
            "Smart rewind must be gated on the user setting (default off), not run unconditionally."
        )
        #expect(
            src.contains("settings?.rewindPauseSecondsThreshold"),
            "Smart-rewind thresholds must come from settings, not a hardcoded policy.")
    }

    // MARK: MacSettingsView surfaces

    @Test func settingsExposeBoostAmountAndSmartRewind() throws {
        let src = try MacSource.read("Views/MacSettingsView.swift")
        #expect(
            src.contains("Boost Amount"),
            "Settings must expose a Volume-Boost dB control so the gain is adjustable on macOS.")
        #expect(
            src.contains("$settings.isRewindEnabled"),
            "Settings must expose a Smart Rewind toggle so the Playback popover SettingsLink leads somewhere real."
        )
    }

    @Test func appearanceFooterDropsFalseArtworkClaim() throws {
        let src = try MacSource.read("Views/MacSettingsView.swift")
        #expect(
            !src.contains("derives the accent from the current book cover"),
            "The Appearance footer must not claim artwork-derived theming that macOS does not implement."
        )
    }

    // MARK: Transport call sites

    @Test func transportButtonsUseDirectionalSkips() throws {
        let triPane = try MacSource.read("Views/MacTriPaneView.swift")
        #expect(
            triPane.contains("player.skipBackward()") && triPane.contains("player.skipForward()"),
            "The transport buttons must route through the directional skip methods.")
        let app = try MacSource.read("Echo_macOSApp.swift")
        #expect(
            app.contains("player.skipBackward()") && app.contains("player.skipForward()"),
            "The Playback menu skip commands must route through the directional skip methods.")
    }

    @Test func skipDurationChangesReachTheLivePlayer() throws {
        let src = try MacSource.read("Views/MacTriPaneView.swift")
        #expect(
            src.contains("onChange(of: settings.seekForwardDuration)"),
            "Forward skip-duration changes from Preferences must reach the live player, not only at launch."
        )
        #expect(
            src.contains("onChange(of: settings.seekBackwardDuration)"),
            "Backward skip-duration changes from Preferences must reach the live player, not only at launch."
        )
    }
}
