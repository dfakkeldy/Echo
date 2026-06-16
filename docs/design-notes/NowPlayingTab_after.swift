// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct NowPlayingTab: View {
    let showsBookSettings: Bool
    let openFolder: () -> Void
    let showHelp: () -> Void
    let showBookSettings: () -> Void
    let showSettings: () -> Void
    let onCreateBookmark: (BookmarkDraft) -> Void

    @Environment(PlayerModel.self) private var model
    @Environment(SettingsManager.self) private var settings

    var body: some View {
            let extractedColor: Color = {
                if let img = model.currentDisplayArtwork ?? model.thumbnailImage,
                   let uiColor = img.averageColor {
                    return Color(uiColor: uiColor)
                }
                return .accentColor
            }()
            
            let bottomTextColor: Color = {
                if let img = model.currentDisplayArtwork ?? model.thumbnailImage,
                   let bottomColor = img.bottomAreaAverageColor {
                    return bottomColor.isLight ? .black : .white
                }
                return .primary
            }()

            ZStack(alignment: .top) {
                // 1. ROOT BACKGROUND
                Color(uiColor: .systemBackground)
                    .ignoresSafeArea()
                
                // 2. THE MAIN STACK
                VStack(spacing: 0) {
                    
                    // --- ARTWORK & OVERLAYS ---
                    ZStack(alignment: .top) {
                        
                        // A. Artwork & Bottom Overlays (Base Layer)
                        ZStack(alignment: .bottom) {
                            // Full Bleed Image
                            if let image = model.currentDisplayArtwork ?? model.thumbnailImage {
                                Image(uiImage: image)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxWidth: .infinity)
                                    // Add this mask modifier:
                                    .mask(
                                        LinearGradient(
                                            stops: [
                                                .init(color: .accentColor, location: 0.0), // 0% opacity at the exact top edge
                                                .init(color: .accentColor, location: 0.3) // 100% opacity 15% of the way down
                                            ],
                                            startPoint: .top,
                                            endPoint: .bottom
                                        )
                                    )
                            } else {
                                Image(systemName: "music.note")
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .padding(40)
                                    .frame(maxWidth: .infinity)
                                    .foregroundStyle(.secondary)
                                    .background(Color(uiColor: .secondarySystemBackground))
                            }
                            
                            // Bottom Overlays: Text & Global Progress
                            VStack(alignment: .leading, spacing: 3) {
                                Text(titleText)
                                    .customFont(.title3, weight: .bold, appFont: model.resolvedAppFont)
                                    .foregroundStyle(bottomTextColor)
                                    .multilineTextAlignment(.leading)
                                    .lineLimit(2)

                                if model.chapters.count >= 2 {
                                    Text(chapterProgressText())
                                        .customFont(.subheadline, appFont: model.resolvedAppFont)
                                        .foregroundStyle(bottomTextColor.opacity(0.8))
                                        .multilineTextAlignment(.leading)
                                        .lineLimit(2)
                                } else if !model.tracks.isEmpty {
                                    Text(trackProgressText())
                                        .customFont(.subheadline, appFont: model.resolvedAppFont)
                                        .foregroundStyle(bottomTextColor.opacity(0.8))
                                        .multilineTextAlignment(.leading)
                                        .lineLimit(2)
                                }
                            }
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(
                                Capsule()
                                    .fill(bottomTextColor == .black ? Color.white.opacity(0.4) : Color.black.opacity(0.4))
                            )
                            .overlay(
                                Capsule()
                                    .stroke(bottomTextColor.opacity(0.15), lineWidth: 1)
                            )
                            .padding(.bottom, 12) // extra bottom padding so text doesn't overlap bar
                            .frame(maxWidth: .infinity, alignment: .leading)
                            
                            // Global Progress Bar pinned to absolute bottom of image
                            GlobalBookProgressBar(fillColor: bottomTextColor)
                                .padding(.horizontal, 16)
                                .padding(.bottom, 4)
                        }
                        .padding(.top, NowPlayingLayout.topOverlayHeight)
                        
                        // B. The Blending Scrim (Middle Layer)
                        // B. The Blending Scrim (Middle Layer)
                                            // Fades from NOTHING at the top, to the extracted color at the bottom
                                            LinearGradient(
                                                colors: [.clear, extractedColor.opacity(1)],
                                                startPoint: .top,
                                                endPoint: .bottom
                                            )
                                            // Change the +30 to +10 or +15 to reduce how far it bleeds into the image
                                            .frame(height: NowPlayingLayout.topOverlayHeight + 0)
                                            .allowsHitTesting(false)                        // C. Absolute Top: Navigation Buttons (Top Layer)
                        HStack {
                            Button(action: openFolder) {
                                Image(systemName: "folder")
                                    .font(.title3.weight(.semibold))
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                                    .foregroundStyle(extractedColor)
                                
                            }
                            .accessibilityLabel(Text("Open folder"))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .background(.regularMaterial, in: Capsule())
                            .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1))
                            .shadow(color: Color.black.opacity(0.2), radius: 5, x: 0, y: 2)
                            
                            
                            Spacer()
                            
                            Text(Duration.seconds(model.currentPlaybackTime).formatted(.time(pattern: .minuteSecond)))
                                .font(.subheadline.monospacedDigit().bold())
                                .foregroundStyle(extractedColor)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(.regularMaterial, in: Capsule())
                                .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1))
                                .shadow(color: Color.black.opacity(0.2), radius: 5, x: 0, y: 2)
                            
                            Spacer()
                            
                            Menu {
                                Button { showSettings() } label: { Label("Global Settings", systemImage: "gearshape") }
                                if showsBookSettings {
                                    Button { showBookSettings() } label: { Label("Book Settings", systemImage: "document.badge.gearshape") }
                                }
                                Button { showHelp() } label: { Label("Help", systemImage: "questionmark.circle") }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .font(.title3.weight(.semibold))
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                                    .foregroundStyle(extractedColor)
                            }
                            .accessibilityLabel(Text("More"))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                            .background(.regularMaterial, in: Capsule())
                            .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1))
                            .shadow(color: Color.black.opacity(0.2), radius: 5, x: 0, y: 2)
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, NowPlayingLayout.topToolbarTopPadding)
                        .zIndex(1) // Enforces that these stay on top of the scrim
                    }
                    
                    // --- CHAPTER SCRUBBER ---
                    PlayerScrubberView()
                        .padding(.horizontal, NowPlayingLayout.horizontalPadding)
                        .padding(.top, 16)
                        .tint(extractedColor)
                    
                    Spacer(minLength: 0)

                    // --- BOTTOM DECK ---
                    VStack(spacing: 16) {
                        TransportControlsView()
                            .padding(.horizontal, 16)
                            .padding(.vertical, 16)
                            .playerDeckSurface()
                            .padding(.horizontal, NowPlayingLayout.horizontalPadding)
                            .padding(.bottom, 8)

                        BottomToolbarView(onCreateBookmark: onCreateBookmark)
                            .playerDeckSurface()
                            .padding(.horizontal, NowPlayingLayout.horizontalPadding)
                    }
                }
                .ignoresSafeArea(.container, edges: .top)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .environment(\.font, model.resolvedAppFont == SettingsManager.systemFontName ? .body : .custom(model.resolvedAppFont, size: 17, relativeTo: .body))
                .grayscale(model.isPlayingVoiceMemo ? 1.0 : 0.0)
                .opacity(model.isPlayingVoiceMemo ? 0.5 : 1.0)
                .allowsHitTesting(!model.isPlayingVoiceMemo)

                if model.isPlayingVoiceMemo { VoiceMemoOverlayView() }

                if let card = model.activeInlineCard {
                    FlashcardOverlayView(
                        card: card,
                        onGrade: { grade in model.gradeInlineFlashcard(grade) },
                        onDismiss: { model.dismissInlineFlashcard() }
                    )
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: model.isPlayingVoiceMemo)
            .animation(.easeInOut(duration: 0.2), value: model.isShowingInlineFlashcard)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        }
    private var titleText: String {
        model.chapters.count >= 2
            ? (model.currentSubtitle.isEmpty ? String(localized: "Ch \((model.currentChapterIndex ?? 0) + 1)") : model.currentSubtitle)
            : model.currentTitle
    }

    private func formatHhMm(_ seconds: Double) -> String {
        let totalMinutes = Int(seconds / 60.0)
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        if h > 0 { return String(format: "%dh%02dm", h, m) }
        else { return "\(m)m" }
    }

    private func bookProgressParts() -> (elapsed: String, remaining: String) {
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
        let scaledElapsed = elapsedSeconds / speed
        let scaledDuration = totalBookDuration / speed
        let scaledRemaining = max(0, scaledDuration - scaledElapsed)
        return (formatHhMm(scaledElapsed), formatHhMm(scaledRemaining))
    }

    private func chapterProgressText() -> String {
        let chapterIndex = (model.currentChapterIndex ?? 0) + 1
        let chapterCount = model.chapters.count
        let parts = bookProgressParts()
        return String(localized: "Ch \(chapterIndex) of \(chapterCount), \(parts.elapsed) elapsed, \(parts.remaining) remaining")
    }

    private func trackProgressText() -> String {
        let trackIndex = model.currentIndex + 1
        let trackCount = model.tracks.count
        let parts = bookProgressParts()
        return String(localized: "Track \(trackIndex) of \(trackCount), \(parts.elapsed) elapsed, \(parts.remaining) remaining")
    }
}

struct GlobalBookProgressBar: View {
    @Environment(PlayerModel.self) private var model
    let fillColor: Color

    var body: some View {
        let enabledChapters = model.chapters.filter { $0.isEnabled }
        let totalDuration = enabledChapters.reduce(0.0) { $0 + max(0, $1.endSeconds - $1.startSeconds) }
        
        GeometryReader { proxy in
            HStack(spacing: 2) {
                if enabledChapters.isEmpty {
                    Capsule()
                        .fill(fillColor)
                        .frame(height: 4)
                } else {
                    let currentIdx = model.currentChapterIndex ?? 0
                    let spacingWidth = CGFloat(max(0, enabledChapters.count - 1)) * 2.0
                    let availableWidth = max(0, proxy.size.width - spacingWidth)
                    
                    ForEach(enabledChapters) { chapter in
                        let chapterDuration = max(0, chapter.endSeconds - chapter.startSeconds)
                        let proportion = totalDuration > 0 ? (chapterDuration / totalDuration) : (1.0 / Double(enabledChapters.count))
                        let segmentWidth = availableWidth * CGFloat(proportion)
                        
                        Capsule()
                            .fill(chapter.index <= currentIdx ? fillColor : fillColor.opacity(0.3))
                            .frame(width: max(2, segmentWidth), height: 4)
                    }
                }
            }
        }
        .frame(height: 4)
    }
}

/// Shared "glass pill" surface for the Now Playing bottom deck, so the
/// transport controls and the bottom toolbar always render an identical
/// background. Mirrors the original `BottomToolbarView` styling: ultra-thin
/// material, a hairline top highlight, and a soft drop shadow.
private struct PlayerDeckSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 5)
    }
}

private extension View {
    /// Applies the shared Now Playing control-deck surface (see `PlayerDeckSurface`).
    func playerDeckSurface() -> some View {
        modifier(PlayerDeckSurface())
    }
}
