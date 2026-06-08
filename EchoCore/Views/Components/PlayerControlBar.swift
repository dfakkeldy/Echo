import SwiftUI

struct PlayerControlBar: View {
    @Environment(PlayerModel.self) private var model
    @Environment(SettingsManager.self) private var settings

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                model.selectedTab = .nowPlaying
            }
            Haptic.play(.medium)
        } label: {
            HStack(spacing: 12) {
                // Artwork / Cover
                if let image = model.currentDisplayArtwork ?? model.thumbnailImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .shadow(color: Color.black.opacity(0.1), radius: 2, x: 0, y: 1)
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 40, height: 40)
                        .overlay {
                            Image(systemName: "book.closed.fill")
                                .foregroundStyle(Color.accentColor)
                                .font(.system(size: 16))
                        }
                }

                // Metadata Details
                VStack(alignment: .leading, spacing: 2) {
                    MarqueeText(
                        text: titleText,
                        fontStyle: .subheadline,
                        fontWeight: .semibold,
                        appFont: settings.appFont,
                        foregroundStyle: .primary
                    )
                    
                    if model.chapters.count >= 2 && !model.currentTitle.isEmpty {
                        Text(model.currentTitle)
                            .customFont(.caption, weight: .regular, appFont: settings.appFont)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                // Play / Pause Button
                Button {
                    model.togglePlayPause()
                    Haptic.play(.light)
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title3)
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(model.isPlaying ? Text("Pause") : Text("Play"))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Mini-player"))
        .accessibilityValue(accessibilityValueText)
        .accessibilityHint(Text("Double tap to open full player"))
    }

    private var titleText: String {
        if model.chapters.count >= 2 {
            return model.currentSubtitle.isEmpty
                ? String(localized: "Ch \((model.currentChapterIndex ?? 0) + 1)")
                : model.currentSubtitle
        } else {
            return model.currentTitle
        }
    }

    private var accessibilityValueText: String {
        let status = model.isPlaying ? String(localized: "Playing") : String(localized: "Paused")
        if model.chapters.count >= 2 && !model.currentTitle.isEmpty {
            return "\(titleText), \(model.currentTitle), \(status)"
        } else {
            return "\(titleText), \(status)"
        }
    }
}
