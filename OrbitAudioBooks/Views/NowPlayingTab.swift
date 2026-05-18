import SwiftUI

struct NowPlayingTab: View {
    @Binding var showingPlaylist: Bool
    @Binding var newBookmarkDraft: BookmarkDraft?
    @Binding var editingBookmarkID: UUID?
    @Binding var isTranscriptExpanded: Bool
    @Environment(PlayerModel.self) private var model
    @Environment(SettingsManager.self) private var settings

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            ZStack {
                VStack(alignment: .leading, spacing: 16) {
                    TranscriptOverlayView(isExpanded: $isTranscriptExpanded) {
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
                    }

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

            BottomToolbarView(
                showingPlaylist: $showingPlaylist,
                onCreateBookmark: { draft in newBookmarkDraft = draft }
            )
        }
        .environment(\.font, settings.appFont == SettingsManager.systemFontName ? .body : .custom(settings.appFont, size: 17, relativeTo: .body))
        .padding(.horizontal)
        .padding(.top)
    }
}
