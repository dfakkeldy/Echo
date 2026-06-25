// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct PlayerControlBar: View {
    @Environment(PlayerModel.self) private var model
    @Environment(SettingsManager.self) private var settings

    var body: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                model.selectedTab = .nowPlaying
            }
            Haptic.play(.medium)
        } label: {
            HStack(spacing: 12) {
                // Artwork / Cover
                if let image = model.currentDisplayArtwork ?? model.thumbnailImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 40, height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .shadow(color: Color.black.opacity(0.1), radius: 2, x: 0, y: 1)
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill((model.resolvedThemeTint ?? Color.accentColor).opacity(0.12))
                        .frame(width: 40, height: 40)
                        .overlay {
                            Image(systemName: "book.closed.fill")
                                .foregroundStyle(model.resolvedThemeTint ?? Color.accentColor)
                                .font(.system(size: 16))
                        }
                }

                // Metadata Details — single line; the chapter title carries
                // identity here, book identity lives in the full player.
                MarqueeText(
                    text: titleText,
                    fontStyle: .subheadline,
                    fontWeight: .semibold,
                    appFont: settings.appFont,
                    foregroundStyle: .primary
                )

                Spacer(minLength: 4)

                // Three user-configurable slots (default −30 · play · +30).
                HStack(spacing: 2) {
                    ForEach(Array(settings.miniPlayerPage.prefix(3).enumerated()), id: \.offset) { _, action in
                        miniSlotButton(action)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("Mini-player"))
        .accessibilityValue(accessibilityValueText)
        .accessibilityHint(Text("Double tap to open full player"))
    }

    @ViewBuilder
    private func miniSlotButton(_ action: WatchAction) -> some View {
        Button {
            perform(action)
        } label: {
            Image(systemName: iconName(for: action))
                .font(.title3)
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text(accessibilityName(for: action)))
    }

    private func iconName(for action: WatchAction) -> String {
        switch action {
        case .playPause: return model.isPlaying ? "pause.fill" : "play.fill"
        case .skipBackward: return WatchAction.skipBackward.dynamicIconName(forDuration: settings.seekBackwardDuration)
        case .skipForward: return WatchAction.skipForward.dynamicIconName(forDuration: settings.seekForwardDuration)
        default: return action.iconName
        }
    }

    private func perform(_ action: WatchAction) {
        switch action {
        case .playPause:
            model.togglePlayPause()
            Haptic.play(.light)
        case .skipBackward:
            _ = model.skipBackward30()
            Haptic.play(.light)
        case .skipForward:
            _ = model.skipForward30()
            Haptic.play(.light)
        case .previousTrack:
            _ = model.skipBackwardNavigation()
            Haptic.play(.light)
        case .nextTrack:
            _ = model.skipForwardNavigation()
            Haptic.play(.light)
        case .previousSection:
            model.previousSectionOrRestart()
            Haptic.play(.light)
        case .nextSection:
            model.nextSection()
            Haptic.play(.light)
        case .loopMode:
            model.cycleLoopMode()
            Haptic.play(.medium)
        case .bookmark:
            if let draft = model.bookmarkDraftAtCurrentTime() {
                model.activeBookmarkDraft = draft
                Haptic.play(.medium)
            }
        case .markPassage:
            model.markPassageAtCurrentTime()
            Haptic.play(.light)
        case .speed:
            let speeds = SettingsManager.Defaults.speedPresets
            if let index = speeds.firstIndex(of: model.speed) {
                model.setSpeed(speeds[(index + 1) % speeds.count])
            } else {
                model.setSpeed(1.0)
            }
            Haptic.play(.medium)
        case .sleepTimer, .pomodoro, .empty:
            break
        }
    }

    private func accessibilityName(for action: WatchAction) -> String {
        switch action {
        case .playPause: return model.isPlaying ? String(localized: "Pause") : String(localized: "Play")
        case .skipBackward: return String(localized: "Skip back \(settings.seekBackwardDuration) seconds")
        case .skipForward: return String(localized: "Skip forward \(settings.seekForwardDuration) seconds")
        case .previousTrack: return String(localized: "Previous chapter")
        case .nextTrack: return String(localized: "Next chapter")
        case .previousSection: return String(localized: "Previous section")
        case .nextSection: return String(localized: "Next section")
        case .loopMode: return String(localized: "Loop mode")
        case .bookmark: return String(localized: "Add bookmark")
        case .markPassage: return String(localized: "Mark passage for later")
        case .speed: return String(localized: "Playback speed")
        case .sleepTimer, .pomodoro, .empty: return ""
        }
    }

    private var titleText: String {
        if model.chapters.count >= 2 {
            return model.currentSubtitle.isEmpty
                ? String(localized: "Ch \((model.currentChapterIndex ?? 0) + 1)")
                : model.currentSubtitle
        } else {
            return model.currentTitle
        }
    }

    private var accessibilityValueText: String {
        let status = model.isPlaying ? String(localized: "Playing") : String(localized: "Paused")
        if model.chapters.count >= 2 && !model.currentTitle.isEmpty {
            return "\(titleText), \(model.currentTitle), \(status)"
        } else {
            return "\(titleText), \(status)"
        }
    }
}
