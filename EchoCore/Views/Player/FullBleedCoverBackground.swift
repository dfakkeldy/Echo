// SPDX-License-Identifier: GPL-3.0-or-later
#if canImport(UIKit)
    import SwiftUI

    /// Spec §5.2 "cover-to-theme blend": the cover aspect-fills the top of the
    /// screen, bleeding off the top and sides, then dissolves via an opacity
    /// mask into the cover-derived AdaptiveBackground wash beneath. The wash is
    /// the bottom layer, so the fade reveals it rather than a hard color.
    struct FullBleedCoverBackground: View {
        @Environment(PlayerModel.self) private var model

        /// Fraction of container height the cover occupies before fully fading.
        static let coverHeightFraction: CGFloat = 0.58
        /// Fade begins at this fraction of the cover's own height.
        static let fadeStartFraction: CGFloat = 0.55

        var body: some View {
            ZStack(alignment: .top) {
                AdaptiveBackground()

                if let image = model.currentDisplayArtwork ?? model.thumbnailImage {
                    Color.clear
                        .overlay(alignment: .top) {
                            Image(uiImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        }
                        .containerRelativeFrame(.vertical, alignment: .top) { height, _ in
                            height * Self.coverHeightFraction
                        }
                        .clipped()
                        .mask(
                            LinearGradient(
                                stops: [
                                    .init(color: .black, location: 0),
                                    .init(color: .black, location: Self.fadeStartFraction),
                                    .init(color: .clear, location: 1),
                                ],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .accessibilityHidden(true)  // decorative; the tappable cover carries the label
                }
            }
            .ignoresSafeArea()
        }
    }
#endif
