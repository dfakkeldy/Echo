// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct PlaybackOptionsSheetTests {
    @Test func sheetContainsSegmentedLoopPicker() throws {
        let source = try Self.source(named: "PlaybackOptionsSheet.swift")
        #expect(
            source.contains("struct PlaybackOptionsSheet"),
            "PlaybackOptionsSheet must be a View struct."
        )
        #expect(
            source.contains("Picker") && source.contains(".pickerStyle(.segmented)"),
            "Loop control must be a segmented Picker."
        )
        #expect(
            source.contains("LoopMode.off") && source.contains("LoopMode.chapter")
                && source.contains("LoopMode.bookmark"),
            "Loop Picker must surface all three LoopMode cases (Off/Chapter/Bookmark)."
        )
        #expect(
            source.contains("setLoopMode"),
            "Loop selection must route through model.setLoopMode to preserve persistence + demotion."
        )
    }

    @Test func sheetSeekSteppersSyncToWatch() throws {
        let source = try Self.source(named: "PlaybackOptionsSheet.swift")
        #expect(
            source.contains("seekForwardDuration") && source.contains("seekBackwardDuration"),
            "Sheet must own the seek-forward/backward duration controls."
        )
        #expect(
            source.contains("model.syncToWatch()"),
            "Seek duration changes must call model.syncToWatch() (side-effect parity with old Settings)."
        )
    }

    @Test func bookmarkLoopShowsUnavailableStateUntilTwoBookmarksExist() throws {
        let source = try Self.source(named: "PlaybackOptionsSheet.swift")
        #expect(
            source.contains("bookmarkLoopUnavailable"),
            "The sheet must model bookmark-loop availability explicitly."
        )
        #expect(
            source.contains("!model.canBookmarkLoop"),
            "Bookmark loop availability must use the shared PlayerModel rule."
        )
        #expect(
            source.contains("if !bookmarkLoopUnavailable {"),
            "The Bookmark segment must not look live while bookmark looping is unavailable; a segmented control ignores per-segment .disabled, so it is hidden."
        )
        #expect(
            source.contains(
                "Add at least two enabled bookmarks on this track to use bookmark looping."),
            "The sheet must explain why Bookmark loop is unavailable."
        )
    }

    /// Council round 4 (P06): the sheet's "Controls" toolbar link duplicated a
    /// route Settings already owns and read as a second exit, so it was
    /// removed. Durable button/layout customization stays reachable from
    /// Settings (pinned by `SettingsExtractionTests`).
    @Test func sheetHasNoSecondExitToControlsSettings() throws {
        let source = try Self.source(named: "PlaybackOptionsSheet.swift")
        #expect(
            !source.contains("PhonePlayerSettingsView()"),
            "Playback Options must not link to Phone Player Settings; Settings reaches it."
        )
        #expect(!source.contains("Label(\"Controls\""))
        #expect(!source.contains("Text(\"More\")"))
        #expect(
            !source.contains("placement: .topBarTrailing"),
            "Done is the sheet's only toolbar button."
        )
    }

    private static func source(named fileName: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()

        while directory.path != "/" {
            let candidate =
                directory
                .deletingLastPathComponent()
                .appendingPathComponent("EchoCore/Views")
                .appendingPathComponent(fileName)

            if FileManager.default.fileExists(atPath: candidate.path) {
                if let content = try? String(contentsOf: candidate, encoding: .utf8) {
                    return content
                }
            }

            directory.deleteLastPathComponent()
        }

        throw CocoaError(.fileNoSuchFile)
    }
}
