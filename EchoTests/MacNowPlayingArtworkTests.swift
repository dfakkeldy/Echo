// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// Structural tests locking the macOS Now Playing cover-art wiring in
/// MacPlayerModel. The `Echo macOS` target is not compiled into EchoTests, so we
/// assert against source text via `MacSource`. Behavioral coverage of the
/// cross-platform artwork path itself lives in `NowPlayingControllerTests`
/// (which runs in the iOS target).
struct MacNowPlayingArtworkTests {

    @Test func modelOwnsCoverImage() throws {
        let src = try MacSource.read("Views/MacPlayerModel.swift")
        #expect(
            src.contains("var coverImage: NSImage?"),
            "MacPlayerModel must own a cover-art NSImage to feed macOS Now Playing.")
    }

    @Test func openExtractsCoverArt() throws {
        let src = try MacSource.read("Views/MacPlayerModel.swift")
        #expect(
            src.contains("loadCoverArt(for:"),
            "open(url:) must kick off cover-art loading for the newly opened file.")
        #expect(
            src.contains(".commonKeyArtwork"),
            "Cover art must be extracted from the audio file's embedded artwork.")
    }

    @Test func staleArtIsClearedOnFileSwap() throws {
        let src = try MacSource.read("Views/MacPlayerModel.swift")
        #expect(
            src.contains("coverImage = nil"),
            "open(url:) must drop the previous file's cover art to avoid stale Now Playing artwork."
        )
    }

    @Test func nowPlayingInfoIncludesArtwork() throws {
        let src = try MacSource.read("Views/MacPlayerModel.swift")
        #expect(
            src.contains("params.artworkImage = coverImage"),
            "updateNowPlaying() must pass the cover image into the Now Playing params.")
    }
}
