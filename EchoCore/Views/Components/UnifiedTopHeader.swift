import SwiftUI

struct UnifiedTopHeader: View {
    @Environment(PlayerModel.self) private var model
    @Environment(SettingsManager.self) private var settings
    
    let onFolderTap: () -> Void
    let onSettingsTap: () -> Void
    let onBookSettingsTap: () -> Void
    let onHelpTap: () -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            // Row 1: Global Navigation Frame (Folder, Remaining Time, Menu)
            HStack {
                Button(action: onFolderTap) {
                    Image(systemName: "folder")
                        .font(.body.bold())
                        .frame(width: 40, height: 40)
                        .background(chipFill, in: Circle())
                        .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                }
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel(Text("Open folder"))
                
                Spacer()

                // Center: the single timer home (audit B1). Book-remaining time
                // moved to the scrubber caption on Now Playing.
                SleepTimerPill()

                Spacer()
                
                // Right: ellipsis menu button
                Menu {
                    // Audit E1: one settings destination — book overrides live
                    // at the top of Settings (and via the player's eyebrow).
                    Button(action: onSettingsTap) {
                        Label("Settings", systemImage: "gearshape")
                    }
                    Button(action: onHelpTap) {
                        Label("Help", systemImage: "questionmark.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.bold())
                        .frame(width: 40, height: 40)
                        .background(chipFill, in: Circle())
                        .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                }
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel(Text("More options"))
            }
            // Align the buttons with each tab's content: 32pt on Now Playing so
            // they sit flush with the artwork edge (not "past the edge"), 16pt
            // elsewhere to match the Timeline/Reader secondary rows.
            .padding(.horizontal, model.selectedTab == .nowPlaying ? NowPlayingLayout.horizontalPadding : 16)
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

