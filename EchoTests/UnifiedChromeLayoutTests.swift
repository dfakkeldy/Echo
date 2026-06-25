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

    @Test func readerHeaderUtilityButtonsMeetTouchTargets() throws {
        let source = try Self.source(named: "ReaderTab.swift")

        #expect(
            source.contains("readerHeaderButtonSize: CGFloat = 44"),
            "Reader header utility buttons must define a 44pt minimum touch target."
        )
        #expect(
            source.contains(".frame(width: readerHeaderButtonSize, height: readerHeaderButtonSize)"),
            "Reader header utility buttons must use the shared 44pt frame."
        )
        #expect(
            !source.contains(".frame(width: 36, height: 36)"),
            "Reader header utility buttons must not regress to 36pt hit targets."
        )
    }

    @Test func readerNoResultsStateOffersRecoveryActions() throws {
        let source = try Self.source(named: "ReaderTab.swift")

        #expect(
            source.contains("vm.showsNoResults"),
            "ReaderTab should render a no-results state when search/filter removes every row."
        )
        #expect(
            source.contains("Label(\"No Results\", systemImage: \"magnifyingglass\")"),
            "Reader no-results state should use a visible, standard unavailable-view label."
        )
        #expect(
            source.contains("Button(\"Clear Search\")"),
            "Reader search misses should offer a one-tap way to clear the query."
        )
        #expect(
            source.contains("Button(\"Show Everything\")"),
            "Reader filter misses should offer a one-tap way to reset feed filters."
        )
    }

    @Test func bottomToolbarSpeedChipAdjustsInlineFromReaderDock() throws {
        let source = try Self.source(named: "BottomToolbarView.swift")

        #expect(
            source.contains("private var speedMenu"),
            "The Reader dock speed chip should be a menu, not only a sheet launcher."
        )
        #expect(
            source.contains("ForEach(SettingsManager.Defaults.speedPresets"),
            "The speed menu should use the app-wide speed presets."
        )
        #expect(
            source.contains("model.setSpeed(preset)"),
            "Selecting a Reader speed preset should adjust the current playback speed inline."
        )
        #expect(
            source.contains("Label(\"Playback Options\", systemImage: \"slider.horizontal.3\")"),
            "The speed menu should keep a path to the full Playback Options sheet for loop and skip settings."
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

    @Test func bottomDockTreatsNarrationBooksAsPlaybackContent() throws {
        let dock = try Self.source(named: "Components/UnifiedBottomDock.swift")
        let toolbar = try Self.source(named: "BottomToolbarView.swift")

        #expect(
            dock.contains("model.hasPlaybackContent"),
            "The root dock should show playback chrome for audio-less EPUB narration books, not just already-rendered tracks."
        )
        #expect(
            toolbar.contains(".disabled(!model.hasPlaybackContent)"),
            "The play/read controls should be available before narration tracks are rendered."
        )
        #expect(
            toolbar.contains(".disabled(model.tracks.isEmpty)"),
            "Timestamp actions such as bookmarks and skipping must still require real tracks."
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
