import CoreGraphics

enum NowPlayingLayout {
    static let horizontalPadding: CGFloat = 24
    static let artworkHorizontalInset: CGFloat = 0
    static let topToolbarTopPadding: CGFloat = 36
    static let topToolbarHeight: CGFloat = 60
    static let topToolbarBottomGap: CGFloat = 24
    static let bottomToolbarClearance: CGFloat = 112
    static let minimumArtworkSize: CGFloat = 160
    static let estimatedControlsHeight: CGFloat = 120

    static var topContentInset: CGFloat {
        topToolbarTopPadding + topToolbarHeight + topToolbarBottomGap
    }

    static var topOverlayHeight: CGFloat {
        topToolbarTopPadding + topToolbarHeight + 16
    }

    static func artworkSize(for size: CGSize) -> CGFloat {
        let availableWidth = max(minimumArtworkSize, size.width - artworkHorizontalInset * 2)
        let heightAvailableForArtwork = size.height
            - topContentInset
            - bottomToolbarClearance
            - estimatedControlsHeight

        return min(availableWidth, max(minimumArtworkSize, heightAvailableForArtwork))
    }
}
