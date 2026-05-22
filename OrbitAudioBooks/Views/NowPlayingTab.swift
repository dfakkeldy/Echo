import SwiftUI

struct NowPlayingTab: View {
    @Environment(PlayerModel.self) private var model
    @Environment(SettingsManager.self) private var settings

    /// Callback invoked when the user taps the bookmark button in the floating toolbar.
    var onCreateBookmark: ((BookmarkDraft) -> Void)?

    var body: some View {
        ZStack(alignment: .bottom) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ZStack {
                        VStack(alignment: .leading, spacing: 16) {
                            AlbumArtHeroView(
                                artwork: model.currentDisplayArtwork ?? model.thumbnailImage,
                                artworkVersion: model.currentDisplayArtworkVersion,
                                caption: model.chapters.count >= 2
                                    ? String(localized: "Current Chapter")
                                    : String(localized: "Book Title"),
                                mainText: model.chapters.count >= 2
                                    ? (model.currentSubtitle.isEmpty
                                        ? String(localized: "Chapter \((model.currentChapterIndex ?? 0) + 1)")
                                        : model.currentSubtitle)
                                    : model.currentTitle,
                                appFont: settings.appFont
                            )

                            Spacer()

                            if model.chapters.count >= 2 {
                                Text(String(localized: "Chapter \((model.currentChapterIndex ?? 0) + 1) of \(model.chapters.count)"))
                                    .customFont(.footnote, appFont: settings.appFont)
                                    .foregroundStyle(.secondary)
                            } else if !model.tracks.isEmpty {
                                Text(String(localized: "Track \(model.currentIndex + 1) of \(model.tracks.count)"))
                                    .customFont(.footnote, appFont: settings.appFont)
                                    .foregroundStyle(.secondary)
                            }

                            PlayerScrubberView()

                            TransportControlsView()
                        }
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

                    // Spacer ensures controls are not obscured by the floating toolbar.
                    Spacer(minLength: 85)
                }
                .environment(\.font, settings.appFont == SettingsManager.systemFontName ? .body : .custom(settings.appFont, size: 17, relativeTo: .body))
                .padding(.horizontal)
                .padding(.top)
            }

            if !model.isPlayingVoiceMemo {
                BottomToolbarView(onCreateBookmark: onCreateBookmark)
            }
        }
    }
}
