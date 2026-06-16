// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics

enum NowPlayingLayout {
    /// Horizontal inset for all Now Playing content (artwork, metadata, scrubber).
    /// Single tuning knob for edge breathing room on the player page.
    static let horizontalPadding: CGFloat = 32
    static let artworkHorizontalInset: CGFloat = 0
    static let topToolbarTopPadding: CGFloat = 36
    static let topToolbarHeight: CGFloat = 60
    static let topToolbarBottomGap: CGFloat = 24
    static let bottomToolbarClearance: CGFloat = 112
    static let estimatedControlsHeight: CGFloat = 120

    static var topContentInset: CGFloat {
        topToolbarTopPadding + topToolbarHeight + topToolbarBottomGap
    }

    static var topOverlayHeight: CGFloat {
        topToolbarTopPadding + topToolbarHeight + 16
    }
}
