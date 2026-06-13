import SwiftUI

struct NowPlayingTab: View {
    let showsBookSettings: Bool
    let openFolder: () -> Void
    let showHelp: () -> Void
    let showBookSettings: () -> Void
    let showSettings: () -> Void
    let onCreateBookmark: (BookmarkDraft) -> Void
    let onShowFidget: (() -> Void)?

    @Environment(PlayerModel.self) private var model
    @Environment(SettingsManager.self) private var settings

    var body: some View {
        ZStack {
            // 1. ADAPTIVE GRADIENT BACKGROUND (Rendered globally at RootTabView)

            // 2. MAIN LAYOUT STACK
            VStack(spacing: 0) {
                // Flexible top slack — balances the artwork block vertically.
                Spacer(minLength: 0)

                // B. Artwork Component
                artworkView
                    .frame(minHeight: 150, maxHeight: 330)

                // C. Metadata & Typography Area
                metadataArea
                    .padding(.horizontal, NowPlayingLayout.horizontalPadding)
                    .padding(.top, 16)

                // D. Main Scrubber (completely exposed, floating over background)
                PlayerScrubberView()
                    .padding(.horizontal, NowPlayingLayout.horizontalPadding)
                    .tint(model.artworkAccentColor ?? .accentColor)
                    .padding(.vertical, 16)

                // Flexible gap: pins the dock to the bottom and keeps the
                // scrubber clearly above the dock capsule.
                Spacer(minLength: 0)

                // E. Unified Bottom Dock
                if !model.isPlayingVoiceMemo {
                    UnifiedBottomDock(onCreateBookmark: onCreateBookmark, onShowFidget: onShowFidget)
                }
            }
            .ignoresSafeArea(.keyboard)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // Reserve room for Row 1 of UnifiedTopHeader (overlaid in RootTabView).
            // Stacks on top of the real status-bar inset, so it's correct on every device.
            .safeAreaInset(edge: .top, spacing: 0) {
                Color.clear.frame(height: 50)
            }
            .environment(\.font, model.resolvedAppFont == SettingsManager.systemFontName ? .body : .custom(model.resolvedAppFont, size: 17, relativeTo: .body))
            .grayscale(model.isPlayingVoiceMemo ? 1.0 : 0.0)
            .opacity(model.isPlayingVoiceMemo ? 0.5 : 1.0)
            .allowsHitTesting(!model.isPlayingVoiceMemo)

            // Voice Memo Overlay
            if model.isPlayingVoiceMemo {
                VoiceMemoOverlayView()
            }

        }
        .animation(.easeInOut(duration: 0.2), value: model.isPlayingVoiceMemo)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
    }

    // MARK: - Subviews





    private var artworkView: some View {
        Group {
            if let image = model.currentDisplayArtwork ?? model.thumbnailImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: 80))
                        .foregroundStyle(.secondary)
                }
                .aspectRatio(1, contentMode: .fit)
            }
        }
        .clipShape(.rect(cornerRadius: 16))
        .padding(.horizontal, NowPlayingLayout.horizontalPadding)
        .shadow(color: .black.opacity(0.25), radius: 16, x: 0, y: 8)
    }

    private var metadataArea: some View {
        VStack(spacing: 5) {
            // Eyebrow: book + author in small caps, tappable → book info (audit B4)
            Button(action: showBookSettings) {
                Text(secondaryLineText)
                    .customFont(.caption, weight: .semibold, appFont: model.resolvedAppFont)
                    .textCase(.uppercase)
                    .kerning(1.1)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .buttonStyle(.plain)
            .disabled(model.folderURL == nil)
            .accessibilityLabel(Text("Book info"))
            .accessibilityValue(Text(secondaryLineText))

            // Hero line: chapter title marquee — almost never truncates now
            MarqueeText(
                text: titleText,
                fontStyle: .title3,
                fontWeight: .bold,
                appFont: model.resolvedAppFont,
                foregroundStyle: .primary
            )
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: - Helpers

    private var titleText: String {
        model.chapters.count >= 2
            ? (model.currentSubtitle.isEmpty ? String(localized: "Ch \((model.currentChapterIndex ?? 0) + 1)") : model.currentSubtitle)
            : model.currentTitle
    }

    private var secondaryLineText: String {
        if model.chapters.count >= 2 {
            let bookTitle = model.currentTitle
            let author = authorText
            return author.isEmpty ? bookTitle : "\(bookTitle) • \(author)"
        } else {
            return authorText.isEmpty ? String(localized: "Audiobook") : authorText
        }
    }

    private var authorText: String {
        if let folderURL = model.folderURL {
            let author = folderURL.deletingLastPathComponent().lastPathComponent
            if author != "Developer" && author != "Documents" && !author.isEmpty {
                return author
            }
        }
        return ""
    }

    private func formatHhMm(_ seconds: Double) -> String {
        let totalMinutes = Int(seconds / 60.0)
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        if h > 0 {
            return "\(h)h\(m.formatted(.number.precision(.integerLength(2))))m"
        } else {
            return "\(m)m"
        }
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

/// Shared "glass pill" surface for the Now Playing bottom deck.
private struct PlayerDeckSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: Capsule())
            .shadow(color: Color.black.opacity(0.2), radius: 5, x: 0, y: 2)
    }
}

private extension View {
    func playerDeckSurface() -> some View {
        modifier(PlayerDeckSurface())
    }
}
