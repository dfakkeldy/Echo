// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct UnifiedTopHeader: View {
    @Environment(PlayerModel.self) private var model
    @Environment(SettingsManager.self) private var settings

    let onFolderTap: () -> Void
    let onSettingsTap: () -> Void
    let onBookSettingsTap: () -> Void
    let onHelpTap: () -> Void
    let onStatsTap: () -> Void
    let onFidgetTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Row 1: Global Navigation Frame (Folder, Remaining Time, Menu)
            HStack {
                Button(action: onFolderTap) {
                    Image(systemName: "folder")
                        .font(.title3.bold())
                        .frame(width: 48, height: 48)
                        .background {
                            Circle()
                                .fill(chipFill)
                                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                        }
                }
                // Use the artwork-derived accent (matches the transport buttons),
                // not the static system blue, so the chrome tints to the cover.
                .foregroundStyle(model.artworkAccentColor ?? Color.accentColor)
                .accessibilityLabel(Text("Open folder"))

                Spacer()

                // Center: the single timer home (audit B1). Book-remaining time
                // moved to the scrubber caption on Now Playing.
                SleepTimerPill()

                Spacer()

                // Right: ellipsis menu button
                Menu {
                    Button(action: onStatsTap) {
                        Label("Stats", systemImage: "chart.bar.fill")
                    }
                    Button(action: onFidgetTap) {
                        Label("Fidget", systemImage: "circle.hexagongrid.fill")
                    }
                    .disabled(model.tracks.isEmpty)
                    Button(action: onSettingsTap) {
                        Label("Settings", systemImage: "gearshape")
                    }
                    Button(action: onHelpTap) {
                        Label("Help", systemImage: "questionmark.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.title3.bold())
                        .frame(width: 48, height: 48)
                        .background {
                            Circle()
                                .fill(chipFill)
                                .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                        }
                }
                .foregroundStyle(model.artworkAccentColor ?? Color.accentColor)
                .accessibilityLabel(Text("More options"))
            }
            // A consistent 16pt inset on every tab. The earlier 32pt on Now
            // Playing pushed the two chips inward toward each other; the larger
            // chips now sit nearer the screen edges, matching the pre-redesign
            // header.
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 8)
        }
        .background(headerBackground)
    }

    @ViewBuilder
    private var headerBackground: some View {
        if model.selectedTab == .nowPlaying {
            Color.clear
        } else {
            Rectangle()
                .fill(.ultraThinMaterial)
                .ignoresSafeArea(edges: .top)
                .shadow(color: Color.black.opacity(0.05), radius: 3, y: 2)
        }
    }

    /// On Now Playing the header chips sit on the tonal ramp, where a solid
    /// chip tone reads as designed; on other tabs they float over scrolling
    /// content, where material blur is still the right call.
    private var chipFill: AnyShapeStyle {
        model.selectedTab == .nowPlaying
            ? AnyShapeStyle(model.coverTheme.chip)
            : AnyShapeStyle(.ultraThinMaterial)
    }

}
