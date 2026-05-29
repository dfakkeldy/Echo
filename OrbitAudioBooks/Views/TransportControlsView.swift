import SwiftUI

struct TransportControlsView: View {
    @Environment(PlayerModel.self) private var model
    @Environment(SettingsManager.self) private var settings

    var body: some View {
        let isCompact = settings.playerLayoutStyle == "compact"
        HStack {
            Spacer()
            ForEach(0..<5, id: \.self) { index in
                let action = actionAt(index)
                buttonForAction(action, isCompact: isCompact)
                Spacer()
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, isCompact ? 8 : 12)
    }

    private func actionAt(_ index: Int) -> WatchAction {
        let page = settings.phonePage
        if page.indices.contains(index) {
            return page[index]
        }
        return .empty
    }

    @ViewBuilder
    private func buttonForAction(_ action: WatchAction, isCompact: Bool) -> some View {
        switch action {
        case .playPause:
            Button {
                model.togglePlayPause()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: isCompact ? 36 : 44, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: isCompact ? 60 : 76, height: isCompact ? 60 : 76)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(model.isPlaying ? Text("Pause") : Text("Play"))

        case .skipBackward:
            Button {
                let didJumpToBookmark = model.skipBackward30()
                UIImpactFeedbackGenerator(style: didJumpToBookmark ? .medium : .light).impactOccurred()
            } label: {
                Image(systemName: WatchAction.skipBackward.dynamicIconName(forDuration: settings.seekBackwardDuration))
                    .font(.system(size: isCompact ? 24 : 28, weight: .regular))
                    .foregroundStyle(.primary)
                    .frame(width: isCompact ? 50 : 64, height: isCompact ? 50 : 64)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("Skip back \(settings.seekBackwardDuration) seconds"))

        case .skipForward:
            Button {
                let didJumpToBookmark = model.skipForward30()
                UIImpactFeedbackGenerator(style: didJumpToBookmark ? .medium : .light).impactOccurred()
            } label: {
                Image(systemName: WatchAction.skipForward.dynamicIconName(forDuration: settings.seekForwardDuration))
                    .font(.system(size: isCompact ? 24 : 28, weight: .regular))
                    .foregroundStyle(.primary)
                    .frame(width: isCompact ? 50 : 64, height: isCompact ? 50 : 64)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("Skip forward \(settings.seekForwardDuration) seconds"))

        case .previousTrack:
            Button {
                let didJumpToBookmark = model.skipBackwardNavigation()
                UIImpactFeedbackGenerator(style: didJumpToBookmark ? .medium : .light).impactOccurred()
            } label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: isCompact ? 20 : 24, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: isCompact ? 50 : 64, height: isCompact ? 50 : 64)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(model.chapters.count >= 2 ? Text("Previous chapter") : Text("Previous track"))

        case .nextTrack:
            Button {
                let didJumpToBookmark = model.skipForwardNavigation()
                UIImpactFeedbackGenerator(style: didJumpToBookmark ? .medium : .light).impactOccurred()
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: isCompact ? 20 : 24, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: isCompact ? 50 : 64, height: isCompact ? 50 : 64)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(model.chapters.count >= 2 ? Text("Next chapter") : Text("Next track"))

        case .previousSection:
            Button {
                model.previousSectionOrRestart()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.system(size: isCompact ? 20 : 24, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: isCompact ? 50 : 64, height: isCompact ? 50 : 64)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("Previous section"))

        case .nextSection:
            Button {
                model.nextSection()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: isCompact ? 20 : 24, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: isCompact ? 50 : 64, height: isCompact ? 50 : 64)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("Next section"))

        case .loopMode:
            Button {
                model.cycleLoopMode()
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            } label: {
                ZStack {
                    switch model.loopMode {
                    case .off:
                        Image(systemName: "infinity")
                            .font(.system(size: isCompact ? 20 : 24, weight: .semibold))
                            .foregroundStyle(.primary)
                    case .chapter:
                        Image(systemName: "infinity")
                            .font(.system(size: isCompact ? 20 : 24, weight: .semibold))
                            .foregroundStyle(.tint)
                    case .bookmark:
                        Image(systemName: "arrow.trianglehead.clockwise")
                            .font(.system(size: isCompact ? 20 : 24, weight: .semibold))
                            .foregroundStyle(.tint)
                            .overlay(
                                Image(systemName: "bookmark.fill")
                                    .font(.system(size: 9, weight: .bold))
                            )
                    }
                }
                .frame(width: isCompact ? 50 : 64, height: isCompact ? 50 : 64)
                .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("Loop mode"))
            .accessibilityValue(Text({
                switch model.loopMode {
                case .off: return String(localized: "Off")
                case .chapter: return String(localized: "Chapter")
                case .bookmark: return String(localized: "Bookmark")
                }
            }()))

        case .speed:
            Button {
                let speeds: [Float] = [1.0, 1.25, 1.5, 2.0, 3.0]
                if let index = speeds.firstIndex(of: model.speed) {
                    let nextIndex = (index + 1) % speeds.count
                    model.setSpeed(speeds[nextIndex])
                } else {
                    model.setSpeed(1.0)
                }
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            } label: {
                Text(speedLabel)
                    .font(.system(size: isCompact ? 14 : 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                    .frame(width: isCompact ? 50 : 64, height: isCompact ? 50 : 64)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("Playback speed"))
            .accessibilityValue(Text(speedLabel))

        case .sleepTimer:
            sleepTimerMenu

        case .bookmark:
            Button {
                if let draft = model.bookmarkDraftAtCurrentTime() {
                    model.activeBookmarkDraft = draft
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
            } label: {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: isCompact ? 20 : 24, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: isCompact ? 50 : 64, height: isCompact ? 50 : 64)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("Add bookmark"))
            .disabled(model.tracks.isEmpty)

        case .empty:
            Spacer()
                .frame(width: isCompact ? 50 : 64, height: isCompact ? 50 : 64)
        }
    }

    private var speedLabel: String {
        switch model.speed {
        case 0.75: return String(localized: "0.75×")
        case 1.0:  return String(localized: "1.0×")
        case 1.25: return String(localized: "1.25×")
        case 1.5:  return String(localized: "1.5×")
        case 1.75: return String(localized: "1.75×")
        case 2.0:  return String(localized: "2.0×")
        default:   return String(format: "%g×", model.speed)
        }
    }

    private var sleepTimerMenu: some View {
        Menu {
            Button {
                model.setSleepTimer(.minutes(15))
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: { Label("15 Minutes", systemImage: "15.circle") }
            Button {
                model.setSleepTimer(.minutes(30))
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: { Label("30 Minutes", systemImage: "30.circle") }
            Button {
                model.setSleepTimer(.minutes(45))
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: { Label("45 Minutes", systemImage: "45.circle") }
            Button {
                model.setSleepTimer(.minutes(60))
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: { Label("1 Hour", systemImage: "1.circle") }
            Divider()
            Button {
                model.setSleepTimer(.endOfChapter)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: { Label("End of Chapter", systemImage: "book.closed") }
            if model.sleepTimerMode.isActive {
                Divider()
                Button(role: .destructive) {
                    model.cancelSleepTimer()
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: { Label("Off", systemImage: "xmark.circle") }
            }
        } label: {
            VStack(spacing: 2) {
                Image(systemName: model.sleepTimerMode.isActive ? "moon.zzz.fill" : "moon.zzz")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.primary)
                if model.sleepTimerMode.isActive {
                    Text(model.sleepTimerMode == .endOfChapter ? "EOC" : sleepTimerCountdownText(model.sleepTimerRemainingSeconds))
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                        .monospacedDigit()
                }
            }
            .frame(width: 64, height: 64)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(Text("Sleep Timer"))
        .accessibilityValue(Text({
            switch model.sleepTimerMode {
            case .off: return String(localized: "Off")
            case .minutes(let m):
                return String(localized: "\(m) minutes, \(model.sleepTimerRemainingSeconds) seconds remaining")
            case .endOfChapter: return String(localized: "End of Chapter")
            }
        }()))
    }
}
