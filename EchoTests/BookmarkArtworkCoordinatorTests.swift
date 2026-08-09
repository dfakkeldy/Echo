// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
import UIKit

@testable import Echo

@MainActor
@Suite struct BookmarkArtworkCoordinatorTests {
    /// 1:3 portrait cover: gold field with a vivid plum band across the top
    /// 18% — the geode shape. In the square blur-fill composite the readable
    /// cover occupies only the middle third and the margins repeat the gold,
    /// so the plum's weight share collapses (~11% → ~3%) below the 5%
    /// accent-promotion floor. Extraction must therefore use the source.
    private func goldPlumPortraitCover() -> UIImage {
        let size = CGSize(width: 60, height: 180)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor(red: 0.831, green: 0.627, blue: 0.090, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor(red: 0.50, green: 0.125, blue: 0.75, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height * 0.18))
        }
    }

    private func plumWeightShare(_ signature: CoverSignature) -> Double {
        let total = signature.candidates.reduce(0) { $0 + $1.weight }
        guard total > 0 else { return 0 }
        let plum = signature.candidates
            .filter { $0.hue > 260 && $0.hue < 340 }
            .reduce(0) { $0 + $1.weight }
        return plum / total
    }

    @Test("base artwork stores the SOURCE cover signature, not the composite's")
    func applyBaseArtworkStoresSourceSignature() throws {
        let state = PlaybackState()
        let coordinator = BookmarkArtworkCoordinator()
        coordinator.state = state

        let source = goldPlumPortraitCover()
        coordinator.applyBaseArtwork(source)

        let sourceSignature = DominantColorExtractor.signature(from: source)
        #expect(state.sourceCoverSignature == sourceSignature)

        // Regression (gold-geode): the source keeps the counter-colour above
        // the 5% promotion floor (CoverThemeBuilder.promotionWeightShare);
        // the blur-fill composite dilutes it below the floor.
        let composite = try #require(state.thumbnailImage)
        let compositeSignature = DominantColorExtractor.signature(from: composite)
        #expect(plumWeightShare(sourceSignature) >= 0.05)
        #expect(plumWeightShare(compositeSignature) < 0.05)
    }

    @Test("missing artwork clears the stored source signature")
    func missingArtworkClearsSourceSignature() {
        let state = PlaybackState()
        let coordinator = BookmarkArtworkCoordinator()
        coordinator.state = state
        coordinator.applyBaseArtwork(goldPlumPortraitCover())

        coordinator.clearUnavailableArtwork()

        #expect(state.sourceCoverSignature == nil)
    }

    @Test("isShowingBookmarkArtwork tracks the display key")
    func isShowingBookmarkArtworkTracksKey() {
        let coordinator = BookmarkArtworkCoordinator()
        #expect(!coordinator.isShowingBookmarkArtwork)
        coordinator.currentDisplayArtworkKey = "base"
        #expect(!coordinator.isShowingBookmarkArtwork)
        coordinator.currentDisplayArtworkKey = "bookmark:0B54:cover.jpg"
        #expect(coordinator.isShowingBookmarkArtwork)
    }

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
