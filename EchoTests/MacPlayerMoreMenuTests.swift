// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct MacPlayerMoreMenuTests {

    @Test("MacPlayerMoreMenu declares the struct")
    func declaresStruct() throws {
        let src = try MacSource.read("Views/MacPlayerMoreMenu.swift")
        #expect(src.contains("struct MacPlayerMoreMenu: View"))
    }

    @Test("MacPlayerMoreMenu wires chapters, bookmarks, passage, sleep, settings")
    func wiresAllActions() throws {
        let src = try MacSource.read("Views/MacPlayerMoreMenu.swift")
        #expect(src.contains("player.seekToChapter"))
        #expect(src.contains("player.jumpTo"))
        #expect(src.contains("player.addBookmarkAtCurrentTime"))
        #expect(src.contains("Open in EchoDeckBuilder"))
        #expect(src.contains("EchoDeckBuilderHandoffService.currentEPUBURL"))
        #expect(src.contains(".disabled(!canOpenInEchoDeckBuilder)"))
        #expect(src.contains(".task(id: echoDeckBuilderAvailabilityKey)"))
        #expect(src.contains("startAccessingSecurityScopedResource()"))
        #expect(src.contains("player.sleepTimerMode"))
        #expect(src.contains("SettingsLink"))
    }

    @Test("MacTriPaneView hosts the More menu in the player bar")
    func triPaneHostsMoreMenu() throws {
        let src = try MacSource.read("Views/MacTriPaneView.swift")
        #expect(src.contains("MacPlayerMoreMenu"))
    }
}
