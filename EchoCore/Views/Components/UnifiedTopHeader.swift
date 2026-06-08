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
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                }
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel(Text("Open folder"))
                
                Spacer()
                
                // Center: overall total time remaining
                remainingTimeView
                
                Spacer()
                
                // Right: ellipsis menu button
                Menu {
                    Button(action: onSettingsTap) {
                        Label("Global Settings", systemImage: "gearshape")
                    }
                    if model.folderURL != nil {
                        Button(action: onBookSettingsTap) {
                            Label("Book Settings", systemImage: "document.badge.gearshape")
                        }
                    }
                    Button(action: onHelpTap) {
                        Label("Help", systemImage: "questionmark.circle")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.body.bold())
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                }
                .foregroundStyle(Color.accentColor)
                .accessibilityLabel(Text("More options"))
            }
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
    
    private var remainingTimeView: some View {
        Group {
            if model.folderURL != nil && !model.tracks.isEmpty {
                Text(formattedRemainingTime)
                    .font(.subheadline.monospacedDigit().bold())
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                    .foregroundStyle(model.artworkAccentColor ?? Color.accentColor)
            } else {
                Text("0:00")
                    .font(.subheadline.monospacedDigit().bold())
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                    .foregroundStyle(.secondary)
            }
        }
    }
    
    private var formattedRemainingTime: String {
        let speed = model.speed > 0 ? Double(model.speed) : 1.0
        let currentSeconds = model.currentPlaybackTime
        let totalBookDuration = model.isMultiM4B ? model.totalBookDuration : (model.durationSeconds ?? 0)
        let elapsedSeconds: Double
        if model.isMultiM4B {
            let bookOffset = model.m4bBooks.indices.contains(model.currentIndex) ? model.m4bBooks[model.currentIndex].cumulativeStartOffset : 0
            elapsedSeconds = bookOffset + currentSeconds
        } else {
            elapsedSeconds = currentSeconds
        }
        let remainingSeconds = max(0, totalBookDuration - elapsedSeconds) / speed
        let total = Int(remainingSeconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            let mStr = m < 10 ? "0\(m)" : "\(m)"
            return "\(h):\(mStr)"
        } else {
            let sStr = s < 10 ? "0\(s)" : "\(s)"
            return "\(m):\(sStr)"
        }
    }
}

