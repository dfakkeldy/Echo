// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct BottomToolbarView: View {
    @Environment(PlayerModel.self) private var model
    @Environment(SettingsManager.self) private var settings
    var onCreateBookmark: ((BookmarkDraft) -> Void)?
    /// Player-More menu closures (WS-C). The actual sheet/tab-switch state lives
    /// on NowPlayingTab; these just forward the user's intent upward.
    var onShowChapters: () -> Void
    var onShowBookmarks: () -> Void
    var onShowSettings: () -> Void
    var onShowPlaybackOptions: () -> Void
    var canCreateReaderCapture: Bool = false
    var isReaderVoiceMemoRecording: Bool = false
    var onAddReaderNote: (@MainActor () -> Void)?
    var onToggleReaderMemo: (@MainActor () -> Void)?
    // onShowFidget removed — Fidget now lives in the More menu (UnifiedTopHeader).

    var body: some View {
        HStack {
            PlayerMoreMenu(
                onShowChapters: onShowChapters,
                onShowBookmarks: onShowBookmarks,
                onShowSettings: onShowSettings
            )
            Spacer()
            speedMenu
            Spacer()
            markPassageButton
            Spacer()
            readToggleButton
            Spacer()
            bookmarkCaptureMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    // MARK: - Mark Passage

    private var markPassageButton: some View {
        Button {
            model.markPassageAtCurrentTime()
            Haptic.play(.light)
        } label: {
            utilityChip(isActive: false) {
                Image(systemName: "rectangle.stack.badge.plus")
                    .font(.title3)
            }
        }
        .accessibilityLabel(Text("Mark passage for later"))
        .disabled(model.tracks.isEmpty)
    }

    // MARK: - Shared chip treatment

    /// All bottom-toolbar chrome uses the cover-derived accent (matching the top
    /// header chips and the rest of the player). The *active* state is still
    /// carried by a filled chip (shape) so it stays distinguishable without
    /// relying on color alone. 44pt target either way.
    private var chromeAccent: Color { model.artworkAccentColor ?? .accentColor }

    private func utilityChip<Content: View>(isActive: Bool, @ViewBuilder content: () -> Content)
        -> some View
    {
        content()
            .frame(width: 44, height: 44)
            .background(
                isActive ? AnyShapeStyle(model.coverTheme.chip) : AnyShapeStyle(.clear),
                in: Circle()
            )
            .contentShape(Rectangle())
            .foregroundStyle(chromeAccent)
    }

    private func utilityTextChip(isActive: Bool, _ text: String) -> some View {
        Text(text)
            .customFont(.headline)
            .padding(.horizontal, 12)
            .frame(minWidth: 44, minHeight: 44)
            .background(
                isActive ? AnyShapeStyle(model.coverTheme.chip) : AnyShapeStyle(.clear),
                in: Capsule()
            )
            .contentShape(Rectangle())
            .foregroundStyle(chromeAccent)
    }

    // MARK: - Speed

    private func speedLabel(_ speed: Float) -> String {
        switch speed {
        case 0.75: return String(localized: "0.75×")
        case 1.0: return String(localized: "1.0×")
        case 1.25: return String(localized: "1.25×")
        case 1.5: return String(localized: "1.5×")
        case 1.75: return String(localized: "1.75×")
        case 2.0: return String(localized: "2.0×")
        case 3.0: return String(localized: "3.0×")
        default: return speed.formatted(.number.precision(.fractionLength(1))) + "×"
        }
    }

    private var speedLabel: String {
        speedLabel(model.speed)
    }

    private var speedMenu: some View {
        Menu {
            ForEach(SettingsManager.Defaults.speedPresets, id: \.self) { preset in
                Button {
                    model.setSpeed(preset)
                    Haptic.play(.medium)
                } label: {
                    Label(
                        speedLabel(preset),
                        systemImage: model.speed == preset ? "checkmark" : "speedometer"
                    )
                }
            }

            Divider()

            Button {
                onShowPlaybackOptions()
                Haptic.play(.light)
            } label: {
                Label("Playback Options", systemImage: "slider.horizontal.3")
            }
        } label: {
            utilityTextChip(isActive: model.speed != 1.0, speedLabel)
        }
        .accessibilityLabel(Text("Playback speed"))
        .accessibilityValue(Text(speedLabel))
        .accessibilityHint(Text("Choose playback speed or open playback options"))
    }

    // MARK: - Read & Study Toggle

    // Two-state toggle between Now Playing and Read.
    private var readToggleButton: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                model.selectedTab = (model.selectedTab == .read) ? .nowPlaying : .read
            }
            Haptic.play(.medium)
        } label: {
            utilityChip(isActive: model.selectedTab == .read) {
                Image(systemName: model.selectedTab == .read ? "book.pages.fill" : "book.pages")
                    .font(.title2)
            }
        }
        .accessibilityLabel(Text(model.selectedTab == .read ? "Now Playing" : "Read & Study"))
        .accessibilityAddTraits(model.selectedTab == .read ? .isSelected : [])
        .disabled(!model.hasPlaybackContent)
    }

    // MARK: - Bookmark

    private var bookmarkCaptureMenu: some View {
        Menu {
            Button {
                createBookmarkDraft()
            } label: {
                Label("Add bookmark", systemImage: "bookmark.fill")
            }
            .disabled(model.tracks.isEmpty)

            Button {
                onAddReaderNote?()
                Haptic.play(.light)
            } label: {
                Label("Add note", systemImage: "note.text.badge.plus")
            }
            .disabled(!canCreateReaderCapture || onAddReaderNote == nil)

            Button {
                onToggleReaderMemo?()
                Haptic.play(isReaderVoiceMemoRecording ? .light : .medium)
            } label: {
                if isReaderVoiceMemoRecording {
                    Label("Stop memo", systemImage: "stop.circle.fill")
                } else {
                    Label("Record memo", systemImage: "mic.circle")
                }
            }
            .disabled(!canCreateReaderCapture || onToggleReaderMemo == nil)
        } label: {
            utilityChip(isActive: isReaderVoiceMemoRecording) {
                Image(systemName: isReaderVoiceMemoRecording ? "mic.circle.fill" : "bookmark.fill")
                    .font(.title2)
            }
        }
        .accessibilityLabel(Text("Bookmark, note, or memo"))
        .disabled(model.tracks.isEmpty && !canCreateReaderCapture)
    }

    private func createBookmarkDraft() {
        if let draft = model.bookmarkDraftAtCurrentTime() {
            onCreateBookmark?(draft)
            Haptic.play(.medium)
        }
    }

    // MARK: - EPUB Player Controls

    private var skipBackwardButton: some View {
        Button {
            model.seek(toSeconds: max(0, model.currentPlaybackTime - 5.0))
            Haptic.play(.light)
        } label: {
            Image(systemName: "gobackward.5")
                .font(.title2)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Text("Skip backward 5 seconds"))
        .disabled(model.tracks.isEmpty)
    }

    private var playPauseButton: some View {
        Button {
            model.togglePlayPause()
            Haptic.play(.medium)
        } label: {
            Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                .font(.title)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Text(model.isPlaying ? "Pause" : "Play"))
        .disabled(!model.hasPlaybackContent)
    }

    private var skipForwardButton: some View {
        Button {
            let duration = model.durationSeconds ?? .infinity
            model.seek(toSeconds: min(duration, model.currentPlaybackTime + 5.0))
            Haptic.play(.light)
        } label: {
            Image(systemName: "goforward.5")
                .font(.title2)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Text("Skip forward 5 seconds"))
        .disabled(model.tracks.isEmpty)
    }
}
