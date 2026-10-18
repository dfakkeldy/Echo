// SPDX-License-Identifier: GPL-3.0-or-later
#if canImport(UIKit)
    import SwiftUI

    /// Experimental full-bleed Now Playing layout (behind
    /// `SettingsManager.experimentalNowPlayingLayout`). Task 0 ships the shell:
    /// standard background + cover + metadata + scrubber, no transport controls
    /// (the shared dock is suppressed; lock screen still controls playback).
    /// Task 1 replaces the background, Task 2 adds the glass control layer.
    struct ExperimentalNowPlayingView: View {
        @Environment(PlayerModel.self) private var model

        let showBookSettings: () -> Void

        var body: some View {
            ZStack {
                FullBleedCoverBackground()

                VStack(spacing: 0) {
                    if let image = model.currentDisplayArtwork ?? model.thumbnailImage {
                        ZoomableArtwork(
                            image: image,
                            accessibilityLabel: Text("Cover of \(model.currentTitle)")
                        ) {
                            Color.clear
                                .contentShape(.rect)
                                .containerRelativeFrame(.vertical) { height, _ in
                                    height * FullBleedCoverBackground.fadeStartFraction
                                        * FullBleedCoverBackground.coverHeightFraction
                                }
                        }
                    } else {
                        Spacer(minLength: 0)
                    }

                    ExperimentalMetadataView(showBookSettings: showBookSettings)
                        .padding(.horizontal, NowPlayingLayout.horizontalPadding)

                    if model.isNarrationBook && NarrationCapability.supportsOnDeviceNarration {
                        NarrationStatusView(state: model.narrationPlaybackState)
                            .padding(.horizontal, NowPlayingLayout.horizontalPadding)
                            .padding(.top, 8)
                    }

                    PlayerScrubberView()
                        .containerRelativeFrame(.horizontal) { width, _ in
                            max(0, width - 2 * NowPlayingLayout.horizontalPadding)
                        }
                        .tint(model.resolvedThemeTint)
                        .padding(.vertical, 16)

                    // Clearance for the control layer's bottom-arc buttons (Task 2).
                    Spacer(minLength: 0)
                        .frame(maxHeight: 160)
                }
            }
        }
    }

    /// Cover image (or placeholder). Same content rules as NowPlayingTab.artworkView.
    struct ExperimentalArtworkView: View {
        @Environment(PlayerModel.self) private var model

        var body: some View {
            Group {
                if let image = model.currentDisplayArtwork ?? model.thumbnailImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .accessibilityLabel(Text("Cover of \(model.currentTitle)"))
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.primary.opacity(0.08))
                        Image(systemName: "book.closed.fill")
                            .font(.system(size: 80))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                    }
                    .aspectRatio(1, contentMode: .fit)
                }
            }
            .clipShape(.rect(cornerRadius: 16))
            .padding(.horizontal, NowPlayingLayout.horizontalPadding)
            .shadow(color: .black.opacity(0.25), radius: 16, x: 0, y: 8)
        }
    }

    /// Book eyebrow + title. Mirrors NowPlayingTab.secondaryLineText composition
    /// (PlayerModel has no single "currentBookTitle" property).
    struct ExperimentalMetadataView: View {
        @Environment(PlayerModel.self) private var model

        let showBookSettings: () -> Void

        private var authorText: String {
            if let author = model.bookMetadataAuthor { return author }
            if let folderURL = model.folderURL {
                let author = folderURL.deletingLastPathComponent().lastPathComponent
                if author != "Developer" && author != "Documents" && !author.isEmpty {
                    return author
                }
            }
            return ""
        }

        private var eyebrowText: String {
            if model.chapters.count >= 2 {
                let bookTitle = model.bookDisplayTitle
                return authorText.isEmpty ? bookTitle : "\(bookTitle) • \(authorText)"
            } else {
                return authorText.isEmpty ? String(localized: "Audiobook") : authorText
            }
        }

        var body: some View {
            VStack(spacing: 5) {
                Button(action: showBookSettings) {
                    Text(eyebrowText)
                        .font(.caption.smallCaps())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens book settings")

                Text(model.currentTitle)
                    .font(.title3.bold())
                    .lineLimit(1)
            }
        }
    }
#endif
