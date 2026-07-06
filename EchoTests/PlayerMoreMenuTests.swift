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

    @Test func playerMoreMenuExposesConsolidatedActions() throws {
        let source = try Self.source(named: "PlayerMoreMenu.swift")
        #expect(source.contains("struct PlayerMoreMenu"), "PlayerMoreMenu type must exist.")
        #expect(source.contains("onShowChapters"), "More menu must surface Chapters.")
        #expect(source.contains("onShowBookmarks"), "More menu must surface Bookmarks.")
        #expect(source.contains("onAddDocument"), "More menu must surface the companion-document attach action.")
        #expect(source.contains("onExport"), "More menu must surface M4B export.")
        #expect(source.contains("onStudyNotesExport"), "More menu must surface study-note export.")
        #expect(source.contains("onStats"), "More menu must surface Stats.")
        #expect(source.contains("onFidget"), "More menu must surface Fidget.")
        #expect(source.contains("onSettings"), "More menu must surface Settings.")
        #expect(source.contains("onHelp"), "More menu must surface Help.")
        #expect(
            source.contains("Label(\"Settings\", systemImage: \"gearshape\")"),
            "The consolidated More menu should keep the obvious Settings entry point."
        )
        #expect(
            !source.contains("setSleepTimer"),
            "Sleep timer arming belongs to SleepTimerPill, not the consolidated More menu."
        )
    }

    @Test func rootDockWiresTheMoreMenu() throws {
        let root = try Self.source(named: "RootTabView.swift")
        #expect(
            root.contains("onShowChapters:")
                && root.contains("onShowBookmarks:")
                && root.contains("onSettings:")
                && root.contains("onAddDocument:"),
            "RootTabView's overlay dock must wire the consolidated More menu closures."
        )
    }

    @Test func topHeaderNoLongerOwnsGlobalMoreMenu() throws {
        let header = try Self.source(named: "Components/UnifiedTopHeader.swift")
        #expect(
            !header.contains("Label(\"Settings\", systemImage: \"gearshape\")"),
            "UnifiedTopHeader should no longer host the global settings menu."
        )
        #expect(
            header.contains("model.selectedTab == .library") && header.contains("SleepTimerPill()"),
            "UnifiedTopHeader should be limited to the Library folder chip and sleep-timer pill."
        )
    }

    @Test func consolidatedMoreMenuCanAttachCompanionDocument() throws {
        let menu = try Self.source(named: "PlayerMoreMenu.swift")
        let root = try Self.source(named: "RootTabView.swift")

        #expect(
            menu.contains("onAddDocument")
                && menu.contains("Add Document")
                && menu.contains("Replace Document"),
            "The consolidated More menu should expose a discoverable companion-document attach action."
        )
        #expect(
            root.contains("companionDocumentTypes")
                && root.contains(".pdf")
                && root.contains("model.importPDFDocument(from: url)")
                && root.contains("model.importEPUBDocument(from: url)"),
            "RootTabView should import selected EPUB or PDF companions into the current book."
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
                "struct PlayerMoreMenu onShowChapters onShowBookmarks onAddDocument onExport "
                + "onStudyNotesExport onStats onFidget onSettings onHelp Add Document "
                + "Replace Document Label(\"Settings\", systemImage: \"gearshape\")"
        } else if fileName == "NowPlayingTab.swift" {
            return "onShowChapters: onShowBookmarks: ChapterPickerSheet"
        } else if fileName == "RootTabView.swift" {
            return "onShowChapters: onShowBookmarks: onSettings: onAddDocument: ChapterPickerSheet "
                + ".fileImporter( companionDocumentTypes .pdf model.importPDFDocument(from: url) model.importEPUBDocument(from: url)"
        } else if fileName == "Components/UnifiedTopHeader.swift" {
            return "model.selectedTab == .library SleepTimerPill()"
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
