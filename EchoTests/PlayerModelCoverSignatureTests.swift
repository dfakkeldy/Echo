// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
import UIKit

@testable import Echo

/// `PlayerModel.currentSignature` must theme from the SOURCE cover's signature
/// (captured at load time) while base artwork is displayed — the displayed
/// images are square blur-fill composites whose margins and scrim dilute small
/// vivid counter-colours below the accent-promotion floor. Bookmark artwork is
/// displayed un-composited, so it keeps per-image extraction.
@MainActor
@Suite struct PlayerModelCoverSignatureTests {
    /// Same geode-shaped fixture as BookmarkArtworkCoordinatorTests: gold 1:3
    /// portrait with a vivid plum band (18% of height). Source extraction
    /// promotes plum to the accent; composite extraction loses it to the
    /// blur-fill margins, so the two themes must differ.
    private func goldPlumPortraitCover() -> UIImage {
        let size = CGSize(width: 60, height: 180)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor(red: 0.831, green: 0.627, blue: 0.090, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor(red: 0.50, green: 0.125, blue: 0.75, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height * 0.18))
        }
    }

    private func solidImage(_ color: UIColor) -> UIImage {
        let size = CGSize(width: 16, height: 16)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }
    }

    @Test("cover theme derives from the source cover, not the blur-fill composite")
    func coverThemeUsesSourceSignature() throws {
        let model = PlayerModel()
        let source = goldPlumPortraitCover()

        model.artworkCoordinator.applyBaseArtwork(source)

        let sourceTheme = CoverThemeBuilder.build(
            from: DominantColorExtractor.signature(from: source), scheme: model.uiColorScheme)
        let composite = try #require(model.thumbnailImage)
        let compositeTheme = CoverThemeBuilder.build(
            from: DominantColorExtractor.signature(from: composite), scheme: model.uiColorScheme)
        // Fixture sanity: the plum share straddles the promotion floor, so the
        // two extraction sources yield distinguishable themes.
        try #require(sourceTheme != compositeTheme)

        #expect(model.coverTheme == sourceTheme)
    }

    @Test("bookmark artwork keeps per-image extraction")
    func bookmarkArtworkKeepsPerImageExtraction() throws {
        let model = PlayerModel()
        model.artworkCoordinator.applyBaseArtwork(goldPlumPortraitCover())
        try #require(model.state.sourceCoverSignature != nil)

        // Simulate an active bookmark image being displayed.
        let bookmarkImage = solidImage(.systemBlue)
        model.artworkCoordinator.currentDisplayArtworkKey = "bookmark:0B54:cover.jpg"
        model.state.currentDisplayArtwork = bookmarkImage
        model.state.currentDisplayArtworkVersion += 1

        let bookmarkTheme = CoverThemeBuilder.build(
            from: DominantColorExtractor.signature(from: bookmarkImage), scheme: model.uiColorScheme
        )
        // The blue bookmark theme is distinguishable from the stored gold/plum
        // source theme, so equality below proves the per-image branch ran.
        let storedTheme = CoverThemeBuilder.build(
            from: try #require(model.state.sourceCoverSignature), scheme: model.uiColorScheme)
        try #require(bookmarkTheme != storedTheme)

        #expect(model.coverTheme == bookmarkTheme)
    }
}
