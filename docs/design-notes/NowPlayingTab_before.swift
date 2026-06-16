// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct NowPlayingTab: View {
    @Environment(PlayerModel.self) private var model
    @Environment(SettingsManager.self) private var settings

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                GeometryReader { proxy in
                    playerContent(proxy: proxy)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .environment(\.font, model.resolvedAppFont == SettingsManager.systemFontName ? .body : .custom(model.resolvedAppFont, size: 17, relativeTo: .body))
            .padding(.top, NowPlayingLayout.topOverlayHeight)
            .padding(.bottom, NowPlayingLayout.bottomToolbarClearance)
            .grayscale(model.isPlayingVoiceMemo ? 1.0 : 0.0)
            .opacity(model.isPlayingVoiceMemo ? 0.5 : 1.0)
            .allowsHitTesting(!model.isPlayingVoiceMemo)

            if model.isPlayingVoiceMemo {
                VoiceMemoOverlayView()
            }

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

    private func playerContent(proxy: GeometryProxy) -> some View {
        let titleText = model.chapters.count >= 2
            ? (model.currentSubtitle.isEmpty
                ? String(localized: "Ch \((model.currentChapterIndex ?? 0) + 1)")
                : model.currentSubtitle)
            : model.currentTitle

        return VStack(alignment: .center, spacing: 0) {
            ZStack(alignment: .bottomLeading) {
                AlbumArtHeroView(
                    artwork: model.currentDisplayArtwork ?? model.thumbnailImage,
                    artworkVersion: model.currentDisplayArtworkVersion,
                    caption: "",
                    mainText: "",
                    appFont: model.resolvedAppFont,
                    isFullBleed: true
                )
                .frame(width: proxy.size.width, height: proxy.size.height * 0.55)
                .clipped()

                // Bottom gradient for text readability
                VStack {
                    Spacer()
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.7)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 120)
                }

                // Title and Progress Text
                VStack(alignment: .leading, spacing: 4) {
                    Text(titleText)
                        .customFont(.title2, weight: .bold, appFont: model.resolvedAppFont)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)

                    if model.chapters.count >= 2 {
                        Text(chapterProgressText())
                            .customFont(.subheadline, appFont: model.resolvedAppFont)
                            .foregroundStyle(.white.opacity(0.8))
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                    } else if !model.tracks.isEmpty {
                        Text(trackProgressText())
                            .customFont(.subheadline, appFont: model.resolvedAppFont)
                            .foregroundStyle(.white.opacity(0.8))
                            .multilineTextAlignment(.leading)
                            .lineLimit(2)
                    }
                }
                .padding(.horizontal, NowPlayingLayout.horizontalPadding)
                .padding(.bottom, 24)
            }
            .frame(width: proxy.size.width, height: proxy.size.height * 0.55)

            VStack(spacing: 24) {
                Spacer(minLength: 0)

                PlayerScrubberView()
                    .padding(.horizontal, NowPlayingLayout.horizontalPadding)

                TransportControlsView()
                    .padding(.horizontal, NowPlayingLayout.horizontalPadding)
                    .padding(.bottom, 8)
                
                Spacer(minLength: 0)
            }
            .frame(width: proxy.size.width, height: proxy.size.height * 0.45)
        }
        .frame(width: proxy.size.width, height: proxy.size.height)
    }

    private func formatHhMm(_ seconds: Double) -> String {
        let totalMinutes = Int(seconds / 60.0)  // truncate toward zero; "2m" at ≥120s, not at 90s
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        if h > 0 {
            return String(format: "%dh%02dm", h, m)
        } else {
            return "\(m)m"
        }
    }

    /// Returns a localized (elapsed, remaining) pair for book-level progress,
    /// accounting for multi-M4B offsets and playback speed.
    private func bookProgressParts() -> (elapsed: String, remaining: String) {
        let speed = model.speed > 0 ? Double(model.speed) : 1.0
        let currentSeconds = model.currentPlaybackTime
        let totalBookDuration = model.isMultiM4B ? model.totalBookDuration : (model.durationSeconds ?? 0)

        let elapsedSeconds: Double
        if model.isMultiM4B {
            let bookOffset = model.m4bBooks.indices.contains(model.currentIndex)
                ? model.m4bBooks[model.currentIndex].cumulativeStartOffset : 0
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
