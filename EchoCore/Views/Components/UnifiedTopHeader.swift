// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct UnifiedTopHeader: View {
    @Environment(PlayerModel.self) private var model
    @Environment(SettingsManager.self) private var settings

    // MARK: - Row 1 layout (single source of truth)

    /// Diameter of the circular navigation chips (folder / ellipsis). The chips
    /// are the tallest element in Row 1, so they govern the row's height.
    static let chipDiameter: CGFloat = 48

    /// Vertical padding wrapping Row 1 above and below the chips.
    static let rowOneVerticalPadding: CGFloat = 8

    /// Total height of Row 1. Every tab that overlays this header in the
    /// `RootTabView` Z-stack must reserve exactly this much top clearance
    /// (`ReaderTab`, `PlaylistView`, `NowPlayingTab`) — otherwise their content
    /// slides up underneath the glass. Deriving it from the same constants the
    /// body lays out with keeps the reservation and the real height from
    /// drifting apart again: they did on 2026-06-20, when the chips grew 40→48
    /// but the hard-coded `50` reservations stayed put, clipping the reader's
    /// chapter-title bar by 14pt.
    static var rowOneHeight: CGFloat { chipDiameter + rowOneVerticalPadding * 2 }

    let onFolderTap: () -> Void
    let onSettingsTap: () -> Void
    let onBookSettingsTap: () -> Void
    let onHelpTap: () -> Void
    let onStatsTap: () -> Void
    let onFidgetTap: () -> Void
    /// Unified ".m4b export" action. `nil` when no book is loaded (nothing to
    /// export); when set, the resolver auto-detects narrated-vs-imported.
    var onExportTap: (() -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            // Row 1: Global Navigation Frame (Folder, Remaining Time, Menu)
            HStack {
                Button(action: onFolderTap) {
                    Image(systemName: "folder")
                        .font(.title3.bold())
                        .frame(width: Self.chipDiameter, height: Self.chipDiameter)
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
                    if let onExportTap {
                        Button(action: onExportTap) {
                            Label("Export Audiobook (.m4b)…", systemImage: "square.and.arrow.up")
                        }
                    }
                    Button(action: onSettingsTap) {
                        Label("Settings", systemImage: "gearshape")
                    }
                    Button(action: onHelpTap) {
                        Label("Help", systemImage: "questionmark.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.title3.bold())
                        .frame(width: Self.chipDiameter, height: Self.chipDiameter)
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
            .padding(.top, Self.rowOneVerticalPadding)
            .padding(.bottom, Self.rowOneVerticalPadding)
        }
        .background(headerBackground)
    }

    /// The header bar itself is fully transparent on every tab — the chips
    /// float over the content (or the tonal ramp on Now Playing) with no scrim.
    /// Legibility comes from each chip's own `chipFill`, not a bar-wide blur.
    private var headerBackground: some View {
        Color.clear
    }

    /// The chips carry their own backing since the bar is transparent: a solid
    /// cover-tonal chip on Now Playing (where it reads against the ramp), and a
    /// material blur on content tabs (where they float over scrolling text and
    /// need the frost to stay legible).
    private var chipFill: AnyShapeStyle {
        model.selectedTab == .nowPlaying
            ? AnyShapeStyle(model.coverTheme.chip)
            : AnyShapeStyle(.ultraThinMaterial)
    }

}
