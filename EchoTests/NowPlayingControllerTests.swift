// SPDX-License-Identifier: GPL-3.0-or-later
import MediaPlayer
import Testing
import UIKit

@testable import Echo

@MainActor
@Suite(.serialized) struct NowPlayingControllerTests {

    @Test func artworkProviderCanBeRequestedOffMainActor() async throws {
        let controller = NowPlayingController()
        let center = MPNowPlayingInfoCenter.default()
        let previousInfo = center.nowPlayingInfo
        defer { center.nowPlayingInfo = previousInfo }

        var params = NowPlayingController.NowPlayingParams()
        params.title = "Artwork isolation test"
        params.artworkImage = UIImage()

        controller.updateNowPlayingInfo(params)

        let artwork = try #require(
            MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork]
                as? MPMediaItemArtwork
        )
        let artworkBox = SendableArtworkBox(artwork)

        let image = try await Task.detached {
            try #require(artworkBox.image(at: CGSize(width: 32, height: 32)))
        }.value

        #expect(image.size == .zero)
    }

    @Test func chapterNumberClearsWhenNextUpdateHasNoChapter() throws {
        let controller = NowPlayingController()
        let center = MPNowPlayingInfoCenter.default()
        let previousInfo = center.nowPlayingInfo
        defer { center.nowPlayingInfo = previousInfo }

        var chapteredParams = NowPlayingController.NowPlayingParams()
        chapteredParams.title = "Chaptered Book"
        chapteredParams.subtitle = "Chapter Three"
        chapteredParams.duration = 100
        chapteredParams.elapsed = 30
        chapteredParams.chapterIndex = 2
        chapteredParams.chapterElapsed = 5
        chapteredParams.chapterDuration = 20
        controller.updateNowPlayingInfo(chapteredParams)

        let chapteredInfo = try #require(MPNowPlayingInfoCenter.default().nowPlayingInfo)
        #expect(chapteredInfo[MPNowPlayingInfoPropertyChapterNumber] as? Int == 3)

        var plainParams = NowPlayingController.NowPlayingParams()
        plainParams.title = "Plain Book"
        plainParams.duration = 50
        plainParams.elapsed = 1
        controller.updateNowPlayingInfo(plainParams)

        let plainInfo = try #require(MPNowPlayingInfoCenter.default().nowPlayingInfo)
        #expect(plainInfo[MPNowPlayingInfoPropertyChapterNumber] == nil)
    }

    /// Regression guard for "Lock Screen shows the ⏸ (pause) button while playback
    /// is already paused" after listening above 1×. On iOS the system infers state
    /// from the current rate, while `DefaultPlaybackRate` identifies the user's
    /// normal listening rate (rather than fast-forwarding).
    @Test func playbackRatesFollowPauseFlagAtConfiguredSpeed() throws {
        let controller = NowPlayingController()
        let center = MPNowPlayingInfoCenter.default()
        let previousInfo = center.nowPlayingInfo
        defer { center.nowPlayingInfo = previousInfo }

        var playing = NowPlayingController.NowPlayingParams()
        playing.title = "Playing Book"
        playing.duration = 100
        playing.isPaused = false
        playing.playbackRate = 2.0
        controller.updateNowPlayingInfo(playing)
        let playingInfo = try #require(MPNowPlayingInfoCenter.default().nowPlayingInfo)
        #expect(
            (playingInfo[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.doubleValue == 2.0)
        #expect(
            (playingInfo[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? NSNumber)?.doubleValue
                == 2.0)

        var paused = NowPlayingController.NowPlayingParams()
        paused.title = "Paused Book"
        paused.duration = 100
        paused.isPaused = true
        paused.playbackRate = 2.0
        controller.updateNowPlayingInfo(paused)
        let pausedInfo = try #require(MPNowPlayingInfoCenter.default().nowPlayingInfo)
        #expect(
            (pausedInfo[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.doubleValue == 0.0)
        #expect(
            (pausedInfo[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? NSNumber)?.doubleValue
                == 2.0)
    }
}

/// Test-only bridge for the Obj-C artwork object that MediaPlayer itself invokes cross-queue.
private struct SendableArtworkBox: @unchecked Sendable {
    nonisolated(unsafe) let artwork: MPMediaItemArtwork

    init(_ artwork: MPMediaItemArtwork) {
        self.artwork = artwork
    }

    nonisolated func image(at size: CGSize) -> UIImage? {
        artwork.image(at: size)
    }
}
