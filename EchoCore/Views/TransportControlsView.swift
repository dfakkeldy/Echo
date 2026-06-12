import SwiftUI

struct TransportControlsView: View {
    @Environment(PlayerModel.self) private var model
    @Environment(SettingsManager.self) private var settings

    var body: some View {
        let isCompact = settings.playerLayoutStyle == "compact"
        HStack(alignment: .center) {
            Spacer()
            ForEach(0..<5, id: \.self) { index in
                let action = actionAt(index)
                let longPressAction = longPressActionAt(index)
                buttonForAction(action, longPressAction: longPressAction, isCompact: isCompact)
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

    private func longPressActionAt(_ index: Int) -> WatchAction {
        let page = settings.phoneLongPressPage
        if page.indices.contains(index) {
            return page[index]
        }
        return .empty
    }

    @ViewBuilder
    private func buttonForAction(_ action: WatchAction, longPressAction: WatchAction, isCompact: Bool) -> some View {
        switch action {
        case .playPause:
            let totalDuration = model.isMultiM4B ? model.totalBookDuration : (model.durationSeconds ?? 0)
            let elapsedSeconds: Double = {
                if model.isMultiM4B {
                    let bookOffset = model.m4bBooks.indices.contains(model.currentIndex) ? model.m4bBooks[model.currentIndex].cumulativeStartOffset : 0
                    return bookOffset + model.currentPlaybackTime
                } else {
                    return model.currentPlaybackTime
                }
            }()
            let totalFraction = totalDuration > 0 ? (elapsedSeconds / totalDuration) : 0.0

            CircularProgressPlayButton(
                isPlaying: model.isPlaying,
                totalProgress: totalFraction,
                chapterProgress: model.progressFraction,
                action: {
                    model.togglePlayPause()
                    Haptic.play(.light)
                },
                longPressAction: longPressAction,
                model: model
            )
            .accessibilityLabel(model.isPlaying ? Text("Pause") : Text("Play"))

        case .skipBackward:
            TransportButton(
                tapAction: {
                    let didJumpToBookmark = model.skipBackward30()
                    Haptic.play(didJumpToBookmark ? .medium : .light)
                },
                longPressAction: longPressAction,
                model: model
            ) {
                Image(systemName: WatchAction.skipBackward.dynamicIconName(forDuration: settings.seekBackwardDuration))
                    .font(.system(size: isCompact ? 22 : 26, weight: .semibold))
                    .foregroundStyle(model.artworkAccentColor ?? .accentColor)
                    .frame(width: isCompact ? 52 : 62, height: isCompact ? 52 : 62)
                    .background(Circle().fill(model.coverTheme.chip))
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("Skip back \(settings.seekBackwardDuration) seconds"))

        case .skipForward:
            TransportButton(
                tapAction: {
                    let didJumpToBookmark = model.skipForward30()
                    Haptic.play(didJumpToBookmark ? .medium : .light)
                },
                longPressAction: longPressAction,
                model: model
            ) {
                Image(systemName: WatchAction.skipForward.dynamicIconName(forDuration: settings.seekForwardDuration))
                    .font(.system(size: isCompact ? 22 : 26, weight: .semibold))
                    .foregroundStyle(model.artworkAccentColor ?? .accentColor)
                    .frame(width: isCompact ? 52 : 62, height: isCompact ? 52 : 62)
                    .background(Circle().fill(model.coverTheme.chip))
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("Skip forward \(settings.seekForwardDuration) seconds"))

        case .previousTrack:
            TransportButton(
                tapAction: {
                    let didJumpToBookmark = model.skipBackwardNavigation()
                    Haptic.play(didJumpToBookmark ? .medium : .light)
                },
                longPressAction: longPressAction,
                model: model
            ) {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: isCompact ? 18 : 20, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: isCompact ? 40 : 44, height: isCompact ? 40 : 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(model.chapters.count >= 2 ? Text("Previous chapter") : Text("Previous track"))

        case .nextTrack:
            TransportButton(
                tapAction: {
                    let didJumpToBookmark = model.skipForwardNavigation()
                    Haptic.play(didJumpToBookmark ? .medium : .light)
                },
                longPressAction: longPressAction,
                model: model
            ) {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: isCompact ? 18 : 20, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: isCompact ? 40 : 44, height: isCompact ? 40 : 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(model.chapters.count >= 2 ? Text("Next chapter") : Text("Next track"))

        case .previousSection:
            TransportButton(
                tapAction: {
                    model.previousSectionOrRestart()
                    Haptic.play(.light)
                },
                longPressAction: longPressAction,
                model: model
            ) {
                Image(systemName: "backward.fill")
                    .font(.system(size: isCompact ? 18 : 20, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: isCompact ? 40 : 44, height: isCompact ? 40 : 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("Previous section"))

        case .nextSection:
            TransportButton(
                tapAction: {
                    model.nextSection()
                    Haptic.play(.light)
                },
                longPressAction: longPressAction,
                model: model
            ) {
                Image(systemName: "forward.fill")
                    .font(.system(size: isCompact ? 18 : 20, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: isCompact ? 40 : 44, height: isCompact ? 40 : 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("Next section"))

        case .loopMode:
            TransportButton(
                tapAction: {
                    model.cycleLoopMode()
                    Haptic.play(.medium)
                },
                longPressAction: longPressAction,
                model: model
            ) {
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
            TransportButton(
                tapAction: {
                    let speeds = SettingsManager.Defaults.speedPresets
                    if let index = speeds.firstIndex(of: model.speed) {
                        let nextIndex = (index + 1) % speeds.count
                        model.setSpeed(speeds[nextIndex])
                    } else {
                        model.setSpeed(1.0)
                    }
                    Haptic.play(.medium)
                },
                longPressAction: longPressAction,
                model: model
            ) {
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
                .phoneLongPressGesture(action: longPressAction, model: model) // Fallback for Menu

        case .bookmark:
            TransportButton(
                tapAction: {
                    if let draft = model.bookmarkDraftAtCurrentTime() {
                        model.activeBookmarkDraft = draft
                        Haptic.play(.medium)
                    }
                },
                longPressAction: longPressAction,
                model: model
            ) {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: isCompact ? 20 : 24, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: isCompact ? 50 : 64, height: isCompact ? 50 : 64)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("Add bookmark"))
            .disabled(model.tracks.isEmpty)

        case .pomodoro:
            Spacer()
                .frame(width: isCompact ? 50 : 64, height: isCompact ? 50 : 64)

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
                Haptic.play(.light)
            } label: { Label("15 Minutes", systemImage: "15.circle") }
            Button {
                model.setSleepTimer(.minutes(30))
                Haptic.play(.light)
            } label: { Label("30 Minutes", systemImage: "30.circle") }
            Button {
                model.setSleepTimer(.minutes(45))
                Haptic.play(.light)
            } label: { Label("45 Minutes", systemImage: "45.circle") }
            Button {
                model.setSleepTimer(.minutes(60))
                Haptic.play(.light)
            } label: { Label("1 Hour", systemImage: "1.circle") }
            Divider()
            Button {
                model.setSleepTimer(.endOfChapter)
                Haptic.play(.light)
            } label: { Label("End of Chapter", systemImage: "book.closed") }
            if model.sleepTimerMode.isActive {
                Divider()
                Button(role: .destructive) {
                    model.cancelSleepTimer()
                    Haptic.play(.light)
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
