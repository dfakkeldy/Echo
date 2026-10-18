// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct ThemeSelectionView: View {
    @Environment(SettingsManager.self) private var settings
    @Environment(PlayerModel.self) private var playerModel

    var body: some View {
        Form {
            Section {
                ForEach(ThemeColor.allCases) { theme in
                    Button {
                        settings.themeColor = theme.rawValue
                    } label: {
                        HStack {
                            if theme == .artwork {
                                artworkPreviewCircle
                            } else if theme != .system {
                                Image(systemName: "circle.fill")
                                    .foregroundStyle(theme.color ?? Color.accentColor)
                            } else {
                                Image(systemName: "circle.fill")
                                    .foregroundStyle(.secondary)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(theme.rawValue)
                                    .foregroundStyle(.primary)
                                if theme == .artwork {
                                    Text("Matches your current book's cover")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }

                            Spacer()

                            if settings.themeColor == theme.rawValue {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                    }
                }
            } footer: {
                if settings.themeColor == ThemeColor.artwork.rawValue,
                    playerModel.artworkAccentColor == nil,
                    playerModel.currentDisplayArtwork == nil,
                    playerModel.thumbnailImage == nil
                {
                    Text("Load an audiobook to see the extracted accent colour.")
                }
            }
        }
        .navigationTitle("Accent Color")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Renders the Artwork option's colour indicator — either the live extracted
    /// colour from the current cover or a fallback placeholder.
    @ViewBuilder
    private var artworkPreviewCircle: some View {
        if playerModel.currentDisplayArtwork != nil || playerModel.thumbnailImage != nil {
            Image(systemName: "circle.fill")
                .foregroundStyle(playerModel.resolvedTint(for: .artwork) ?? Color.accentColor)
        } else {
            Image(systemName: "circle.dashed")
                .foregroundStyle(.secondary)
        }
    }
}
