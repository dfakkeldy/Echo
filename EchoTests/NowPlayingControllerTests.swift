// SPDX-License-Identifier: GPL-3.0-or-later
import MediaPlayer
import Testing
import UIKit

@testable import Echo

@MainActor
@Suite struct NowPlayingControllerTests {

    @Test func artworkProviderCanBeRequestedOffMainActor() async throws {
        let controller = NowPlayingController()

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
