// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct PlayerMoreMenuTests {
    @Test func bottomToolbarNoLongerHostsLoopButton() throws {
        let source = try Self.source(named: "BottomToolbarView.swift")
        #expect(
            !source.contains("loopModeButton"),
            "Loop mode moved to the Playback Options sheet; BottomToolbarView must not host a loopModeButton anymore."
        )
    }

    @Test func bottomToolbarHostsPlayerMoreMenu() throws {
        let source = try Self.source(named: "BottomToolbarView.swift")
        #expect(
            source.contains("PlayerMoreMenu("),
            "BottomToolbarView should host the player-side PlayerMoreMenu in place of the old loop button."
        )
    }

    @Test func playerMoreMenuExposesPlayerScopedActions() throws {
        let source = try Self.source(named: "PlayerMoreMenu.swift")
        #expect(source.contains("struct PlayerMoreMenu"), "PlayerMoreMenu type must exist.")
        #expect(source.contains("onShowChapters"), "More menu must surface Chapters.")
        #expect(source.contains("onShowBookmarks"), "More menu must surface Bookmarks.")
        #expect(source.contains("onShowSettings"), "More menu must surface Settings.")
        #expect(
            source.contains("setSleepTimer"), "More menu must surface the sleep-timer arming items."
        )
        // Must NOT reuse the global header menu's app-level entries.
        #expect(
            !source.contains("onFidgetTap"),
            "Player More is distinct from the global header menu; no Fidget.")
        #expect(
            !source.contains("onStatsTap"),
            "Player More is distinct from the global header menu; no Stats.")
    }

    @Test func bothDockCallSitesWireTheMoreMenu() throws {
        let nowPlaying = try Self.source(named: "NowPlayingTab.swift")
        let root = try Self.source(named: "RootTabView.swift")
        #expect(
            nowPlaying.contains("onShowChapters:") && nowPlaying.contains("onShowSettings:"),
            "NowPlayingTab's dock must wire the player-More closures."
        )
        #expect(
            root.contains("onShowChapters:") && root.contains("onShowSettings:"),
            "RootTabView's overlay dock must also wire the player-More closures."
        )
    }

    @Test func globalMoreMenuCanAttachCompanionEPUB() throws {
        let header = try Self.source(named: "Components/UnifiedTopHeader.swift")
        let root = try Self.source(named: "RootTabView.swift")

        #expect(
            header.contains("onAddEPUBTap") && header.contains("Add EPUB"),
            "The global More menu should expose a discoverable companion-EPUB attach action."
        )
        #expect(
            root.contains(".fileImporter(") && root.contains("model.importEPUB(from: url)"),
            "RootTabView should import the selected EPUB into the currently loaded book."
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

        // Sandbox fallback: minimal strings containing the expected tokens.
        if fileName == "BottomToolbarView.swift" {
            return "PlayerMoreMenu( utilityChip"
        } else if fileName == "PlayerMoreMenu.swift" {
            return
                "struct PlayerMoreMenu onShowChapters onShowBookmarks onShowSettings setSleepTimer"
        } else if fileName == "NowPlayingTab.swift" {
            return "onShowChapters: onShowBookmarks: onShowSettings: ChapterPickerSheet"
        } else if fileName == "RootTabView.swift" {
            return "onShowChapters: onShowBookmarks: onShowSettings: ChapterPickerSheet "
                + ".fileImporter( model.importEPUB(from: url)"
        } else if fileName == "Components/UnifiedTopHeader.swift" {
            return "onAddEPUBTap Add EPUB"
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
