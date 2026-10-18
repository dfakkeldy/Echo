// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct BottomToolbarView: View {
    @Environment(PlayerModel.self) private var model
    @Environment(SettingsManager.self) private var settings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var recentMarkResult: MarkPassageResult?
    @State private var recentMarkResultTask: Task<Void, Never>?

    var onCreateBookmark: ((BookmarkDraft) -> Void)?
    var onMarkPassageResult: (MarkPassageResult) -> Void
    /// Player-More menu closures (WS-C). The actual sheet/tab-switch state lives
    /// on NowPlayingTab; these just forward the user's intent upward.
    var onShowChapters: () -> Void
    var onShowBookmarks: () -> Void
    var onStats: () -> Void
    var onFidget: () -> Void
    var onSettings: () -> Void
    var onHelp: () -> Void
    var onAddDocument: (() -> Void)?
    var onExport: (() -> Void)?
    var onVideoExport: (() -> Void)?
    var onStudyNotesExport: (() -> Void)?
    var onShowPlaybackOptions: () -> Void
    var canCreateReaderCapture: Bool = false
    var isReaderVoiceMemoRecording: Bool = false
    var onAddReaderNote: (@MainActor () -> Void)?
    var onToggleReaderMemo: (@MainActor () -> Void)?
    var onOpenBookOrFolder: (() -> Void)? = nil
    var showsReaderSleepTimer = false

    var body: some View {
        HStack {
            PlayerMoreMenu(
                onShowChapters: onShowChapters,
                onShowBookmarks: onShowBookmarks,
                onStats: onStats,
                onFidget: onFidget,
                onSettings: onSettings,
                onHelp: onHelp,
                onAddDocument: onAddDocument,
                onExport: onExport,
                onVideoExport: onVideoExport,
                onStudyNotesExport: onStudyNotesExport,
                onOpenBookOrFolder: onOpenBookOrFolder,
                showsReaderSleepTimer: showsReaderSleepTimer
            )
            Spacer()
            speedMenu
            Spacer()
            markPassageButton
            Spacer()
            tabCycleButton
            Spacer()
            bookmarkCaptureMenu
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    // MARK: - Mark Passage

    private var markPassageButton: some View {
        Button {
            markPassage()
        } label: {
            utilityChip(isActive: false) {
                Image(systemName: markPassageSystemImage)
                    .font(.title3)
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                    .animation(
                        reduceMotion ? nil : .easeInOut(duration: 0.2),
                        value: recentMarkResult
                    )
            }
        }
        .accessibilityLabel(Text("Mark passage for later"))
        .disabled(!model.canMarkPassage)
    }

    private var markPassageSystemImage: String {
        guard let recentMarkResult else { return "rectangle.stack.badge.plus" }
        return DockStatusFeedback(result: recentMarkResult).systemImage
    }

    private func markPassage() {
        let result = model.markPassageAtCurrentTime()
        switch result {
        case .saved:
            Haptic.notify(.success)
        case .unavailable, .failed:
            Haptic.notify(.error)
        }

        onMarkPassageResult(result)
        recentMarkResultTask?.cancel()
        recentMarkResult = result
        recentMarkResultTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(1.5))
            } catch {
                return
            }
            recentMarkResult = nil
        }
    }

    // MARK: - Shared chip treatment

    /// All bottom-toolbar chrome uses the cover-derived accent (matching the top
    /// header chips and the rest of the player). The *active* state is still
    /// carried by a filled chip (shape) so it stays distinguishable without
    /// relying on color alone. 44pt target either way.
    private var chromeAccent: Color { model.resolvedThemeTint ?? .accentColor }

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

    // MARK: - Tab Cycle

    private var tabCycleButton: some View {
        let next: TabSelection = {
            switch model.selectedTab {
            case .nowPlaying: return .read
            case .read: return .library
            case .library: return .nowPlaying
            }
        }()
        return Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                model.selectedTab = next
            }
            Haptic.play(.medium)
        } label: {
            utilityChip(isActive: false) {
                Image(systemName: next.icon)
                    .font(.title2)
            }
        }
        .accessibilityLabel(Text("Go to \(next.label)"))
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
