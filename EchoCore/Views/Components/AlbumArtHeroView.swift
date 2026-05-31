import SwiftUI

struct AlbumArtHeroView: View {
    let artwork: UIImage?
    let artworkVersion: Int
    let caption: String
    let mainText: String
    let appFont: String
    let maxArtworkSize: CGFloat?

    init(
        artwork: UIImage?,
        artworkVersion: Int,
        caption: String,
        mainText: String,
        appFont: String,
        maxArtworkSize: CGFloat? = nil
    ) {
        self.artwork = artwork
        self.artworkVersion = artworkVersion
        self.caption = caption
        self.mainText = mainText
        self.appFont = appFont
        self.maxArtworkSize = maxArtworkSize
    }

    var body: some View {
        VStack(alignment: .center, spacing: 12) {
            artworkView
                .frame(width: maxArtworkSize, height: maxArtworkSize)
                .frame(maxWidth: .infinity)

            VStack(alignment: .center, spacing: 6) {
                if !caption.isEmpty {
                    Text(caption)
                        .customFont(.caption, appFont: appFont)
                        .foregroundStyle(.secondary)
                }
                Text(mainText)
                    .customFont(.title2, weight: .semibold, appFont: appFont)
                    .foregroundStyle(.tint)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, NowPlayingLayout.horizontalPadding)
        }
    }

    @ViewBuilder
    private var artworkView: some View {
        if let image = artwork {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .id(artworkVersion)
                .transition(.opacity)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 10)
                .accessibilityLabel(Text(mainText))
                .accessibilityAddTraits(.isImage)
        } else {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quaternary)
                .aspectRatio(1, contentMode: .fit)
                .overlay(
                    Image(systemName: "music.note")
                        .font(.system(size: 80, weight: .semibold))
                        .foregroundStyle(.secondary)
                )
                .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 10)
                .accessibilityLabel(Text(caption))
                .accessibilityAddTraits(.isImage)
        }
    }
}
