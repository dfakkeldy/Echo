import SwiftUI

struct UnifiedBottomDock: View {
    @Environment(PlayerModel.self) private var model
    var onCreateBookmark: (BookmarkDraft) -> Void
    var onShowFidget: (() -> Void)?

    private var showsControls: Bool {
        model.selectedTab == .nowPlaying || (model.folderURL != nil && !model.tracks.isEmpty)
    }

    var body: some View {
        // A clean VStack of: controls (or mini-player) → divider → utility toolbar.
        // The capsule gets uniform `.padding(.vertical, 16)` (below) so each row
        // takes its natural, uncompressed height.
        VStack(spacing: 0) {
            // Upper layer: Large Controls (Now Playing) or Mini-player (other tabs)
            if model.selectedTab == .nowPlaying {
                TransportControlsView()
                    .padding(.horizontal, 16)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.95).combined(with: .opacity),
                        removal: .scale(scale: 0.95).combined(with: .opacity)
                    ))
            } else if model.folderURL != nil && !model.tracks.isEmpty {
                PlayerControlBar()
                    .padding(.horizontal, 16)
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.95).combined(with: .opacity),
                        removal: .scale(scale: 0.95).combined(with: .opacity)
                    ))
            }

            // Divider separating controls from utility bar
            if showsControls {
                Divider()
                    .background(Color(uiColor: .separator).opacity(0.25))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }

            // Lower layer: Static 5-Button Utility Bar
            BottomToolbarView(onCreateBookmark: onCreateBookmark, onShowFidget: onShowFidget)
                .padding(.horizontal, 16)
        }
        // Uniform vertical breathing room so the circular play-button progress
        // ring is never clipped by the capsule's rounded corners.
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
        // Tint the system material backdrop with dynamic artwork theme
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(model.artworkAccentColor ?? .accentColor)
                .opacity(0.08)
        )
        .shadow(color: Color.black.opacity(0.25), radius: 15, x: 0, y: 5)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }
}
