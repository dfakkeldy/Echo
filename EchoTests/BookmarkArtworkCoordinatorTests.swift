// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
import UIKit

@testable import Echo

@MainActor
@Suite struct BookmarkArtworkCoordinatorTests {
    @Test("artwork version advances before Now Playing and Watch callbacks")
    func artworkVersionAdvancesBeforePublishing() {
        let state = PlaybackState()
        let coordinator = BookmarkArtworkCoordinator()
        coordinator.state = state

        var versionSeenByNowPlaying: Int?
        var versionSeenByWatch: Int?
        coordinator.onUpdateNowPlaying = { _ in
            versionSeenByNowPlaying = state.currentDisplayArtworkVersion
        }
        coordinator.onSyncToWatch = {
            versionSeenByWatch = state.currentDisplayArtworkVersion
        }

        coordinator.updateCurrentDisplayArtwork(at: 0, force: true)

        #expect(state.currentDisplayArtworkVersion == 1)
        #expect(versionSeenByNowPlaying == 1)
        #expect(versionSeenByWatch == 1)
    }

    @Test("cache invalidation advances the artwork version and clears display state")
    func invalidationAdvancesArtworkVersion() {
        let state = PlaybackState()
        state.currentDisplayArtwork = UIImage()
        state.watchThumbnailData = Data([0x01])
        let coordinator = BookmarkArtworkCoordinator()
        coordinator.state = state

        coordinator.invalidateCache()

        #expect(state.currentDisplayArtworkVersion == 1)
        #expect(state.currentDisplayArtwork == nil)
        #expect(state.watchThumbnailData == nil)
    }

    @Test("missing artwork advances the version before publishing the cleared state")
    func missingArtworkAdvancesBeforePublishing() {
        let state = PlaybackState()
        state.currentDisplayArtwork = UIImage()
        state.watchThumbnailData = Data([0x01])
        let coordinator = BookmarkArtworkCoordinator()
        coordinator.state = state

        var versionSeenByNowPlaying: Int?
        var versionSeenByWatch: Int?
        coordinator.onUpdateNowPlaying = { _ in
            versionSeenByNowPlaying = state.currentDisplayArtworkVersion
        }
        coordinator.onSyncToWatch = {
            versionSeenByWatch = state.currentDisplayArtworkVersion
        }

        coordinator.clearUnavailableArtwork()

        #expect(state.currentDisplayArtworkVersion == 1)
        #expect(versionSeenByNowPlaying == 1)
        #expect(versionSeenByWatch == 1)
        #expect(state.currentDisplayArtwork == nil)
        #expect(state.watchThumbnailData == nil)
    }
}
