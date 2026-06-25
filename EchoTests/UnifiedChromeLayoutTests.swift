// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct UnifiedChromeLayoutTests {
    @Test func readerFiltersCollapseWithHeaderChrome() throws {
        let source = try Self.source(named: "ReaderTab.swift")

        #expect(
            source.contains("private func readerHeaderOverlay(vm: ReaderFeedViewModel)"),
            "ReaderTab should build the reader chrome from the active view model so filters can live inside the collapsing header."
        )
        #expect(
            source.contains("filterBar(vm)"),
            "The content filters should be rendered by the reader header chrome, not as a fixed row above the feed."
        )
        #expect(
            source.contains("readerHeaderOverlay(vm: vm)"),
            "The top safe-area inset should install the view-model-aware reader header."
        )
    }

    @Test func readerHeaderHasSectionChevrons() throws {
        let source = try Self.source(named: "ReaderTab.swift")

        #expect(source.contains("chevron.left"), "Reader header should expose a previous-section chevron.")
        #expect(source.contains("chevron.right"), "Reader header should expose a next-section chevron.")
        #expect(
            source.contains("model.previousSectionOrRestart()"),
            "Previous chevron should reuse the section-aware player navigation."
        )
        #expect(
            source.contains("model.nextSection()"),
            "Next chevron should reuse the section-aware player navigation."
        )
    }

    @Test func bookmarkButtonOpensCaptureMenu() throws {
        let source = try Self.source(named: "BottomToolbarView.swift")

        #expect(source.contains("bookmarkCaptureMenu"), "The bookmark slot should be a menu-backed capture control.")
        #expect(source.contains("Menu {"), "The bookmark slot should open a SwiftUI menu.")
        #expect(source.contains("Label(\"Add bookmark\""), "The menu should include Add bookmark.")
        #expect(source.contains("Label(\"Add note\""), "The menu should include Add note.")
        #expect(source.contains("Label(\"Record memo\""), "The menu should include Record memo.")
        #expect(
            !source.contains("private var addBookmarkButton"),
            "The old immediate bookmark button should be replaced by the capture menu."
        )
    }

    @Test func bottomDockIsRootAnchoredForEveryMainScreen() throws {
        let root = try Self.source(named: "RootTabView.swift")
        let nowPlaying = try Self.source(named: "NowPlayingTab.swift")
        let dock = try Self.source(named: "Components/UnifiedBottomDock.swift")

        #expect(
            root.contains("if !model.isPlayingVoiceMemo"),
            "RootTabView should own the dock overlay for every main tab except voice-memo playback."
        )
        #expect(
            !nowPlaying.contains("UnifiedBottomDock("),
            "NowPlayingTab should reserve clearance for the shared root dock instead of rendering a separate dock."
        )
        #expect(
            dock.contains("bottomEdgePadding"),
            "UnifiedBottomDock should expose a single bottom-edge padding used by the shared overlay."
        )
    }

    @Test func rootBottomChromeDoesNotHostDashboardShelf() throws {
        let root = try Self.source(named: "RootTabView.swift")
        let stats = try Self.source(named: "Stats/StatsView.swift")

        #expect(
            !root.contains("DashboardShelf("),
            "Root bottom chrome must stay progress-first; dashboard modules should not sit above the player dock."
        )
        #expect(
            !root.contains("launchStudySession"),
            "RootTabView should not carry study launch state for the bottom player chrome."
        )
        #expect(
            stats.contains("Button(\"Review Queue\", systemImage: \"rectangle.stack.fill\""),
            "Study review entry should live in Stats instead of competing with the bottom player chrome."
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

            if FileManager.default.fileExists(atPath: candidate.path),
                let content = try? String(contentsOf: candidate, encoding: .utf8)
            {
                return content
            }

            directory.deleteLastPathComponent()
        }

        throw CocoaError(.fileNoSuchFile)
    }
}
