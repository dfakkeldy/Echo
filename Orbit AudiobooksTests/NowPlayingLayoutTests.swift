import Foundation
import CoreGraphics
import Testing
@testable import Orbit_Audiobooks

struct NowPlayingLayoutTests {
    @Test func nowPlayingArtworkCanRenderBehindTopToolbar() throws {
        let source = try Self.source(named: "NowPlayingTab.swift")

        #expect(
            !source.contains(".padding(.top, 60)"),
            "Now Playing must not reserve a fixed black strip above artwork; the transparent top toolbar should float over player content."
        )
        #expect(
            source.contains("NowPlayingLayout.topContentInset"),
            "Now Playing content should keep a named clearance below the floating toolbar so the controls do not block artwork."
        )
    }

    @Test func nowPlayingArtworkGrowsIntoAvailableSpace() {
        let size = CGSize(width: 430, height: 838)

        #expect(
            NowPlayingLayout.artworkSize(for: size) >= 390,
            "On a tall phone layout the artwork should use most of the available width instead of leaving a large empty gap."
        )
    }

    @Test func nowPlayingShrinksArtworkInsteadOfScrolling() throws {
        let nowPlayingSource = try Self.source(named: "NowPlayingTab.swift")
        let heroSource = try Self.source(named: "Components/AlbumArtHeroView.swift")

        #expect(
            !nowPlayingSource.contains("ScrollView"),
            "Now Playing should fit the player by shrinking artwork instead of making the controls scroll."
        )
        #expect(
            nowPlayingSource.contains("artworkSize"),
            "Now Playing should calculate an adaptive artwork size from available height."
        )
        #expect(
            nowPlayingSource.contains("playerContent"),
            "Now Playing should center the player column within the space between the floating toolbars."
        )
        #expect(
            nowPlayingSource.contains("contentWidth"),
            "Now Playing should clamp the player column to the device width so long labels cannot push artwork offscreen."
        )
        #expect(
            heroSource.contains("maxArtworkSize"),
            "Album artwork should accept an explicit max size so the player can fit without scrolling."
        )
    }

    @Test func scrubberKeepsTimeLabelsInsideBounds() throws {
        let source = try Self.source(named: "PlayerScrubberView.swift")

        #expect(
            source.contains("timeLabelWidth"),
            "Scrubber time labels need stable widths so elapsed and remaining time stay aligned."
        )
        #expect(
            source.contains("ViewThatFits"),
            "The scrubber should keep time labels beside the slider when they fit and fall back when space is crowded."
        )
    }

    @Test func nowPlayingUsesOverlayControlsInsteadOfNavigationBar() throws {
        let source = try Self.source(named: "RootTabView.swift")

        #expect(
            source.contains("NowPlayingTopToolbar"),
            "Now Playing top controls should be drawn as an overlay so the navigation bar does not reserve an empty top slab."
        )
        #expect(
            source.contains(".toolbarVisibility(model.showingTimeline ? .automatic : .hidden, for: .navigationBar)"),
            "The navigation bar should be hidden only on Now Playing, while Timeline keeps the standard navigation toolbar."
        )
    }

    private static func source(named fileName: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()

        while directory.path != "/" {
            let candidate = directory
                .deletingLastPathComponent()
                .appendingPathComponent("OrbitAudioBooks/Views")
                .appendingPathComponent(fileName)

            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }

            directory.deleteLastPathComponent()
        }

        throw CocoaError(.fileNoSuchFile)
    }
}
