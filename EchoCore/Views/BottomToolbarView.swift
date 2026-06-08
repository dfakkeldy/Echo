import SwiftUI

struct BottomToolbarView: View {
    @Environment(PlayerModel.self) private var model
    @Environment(SettingsManager.self) private var settings
    var onCreateBookmark: ((BookmarkDraft) -> Void)?

    var body: some View {
        HStack {
            loopModeButton
            Spacer()
            speedButton
            Spacer()
            sleepTimerMenu
            Spacer()
            timelineButton
            Spacer()
            addBookmarkButton
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Loop Mode

    private var loopModeButton: some View {
        Button {
            model.cycleLoopMode()
            Haptic.play(.medium)
        } label: {
            ZStack {
                switch model.loopMode {
                case .off:
                    Image(systemName: "infinity.circle")
                        .font(.title2)
                case .chapter:
                    Image(systemName: "infinity.circle.fill")
                        .font(.title2)
                case .bookmark:
                    Image(systemName: "arrow.trianglehead.clockwise")
                        .font(.title2)
                        .overlay(
                            Image(systemName: "bookmark.fill")
                                .font(.system(size: 9, weight: .bold))
                        )
                }
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .foregroundStyle(model.loopMode != .off ? (model.artworkAccentColor ?? .accentColor) : .secondary)
        .accessibilityLabel(Text("Loop mode"))
        .accessibilityValue(Text({
            switch model.loopMode {
            case .off: return String(localized: "Off")
            case .chapter: return String(localized: "Chapter")
            case .bookmark: return String(localized: "Bookmark")
            }
        }()))
    }

    // MARK: - Speed

    private var speedLabel: String {
        switch model.speed {
        case 0.75: return String(localized: "0.75×")
        case 1.0:  return String(localized: "1.0×")
        case 1.25: return String(localized: "1.25×")
        case 1.5:  return String(localized: "1.5×")
        case 1.75: return String(localized: "1.75×")
        case 2.0:  return String(localized: "2.0×")
        default:   return model.speed.formatted(.number.precision(.fractionLength(1))) + "×"
        }
    }


    private var speedButton: some View {
        Button {
            let speeds = SettingsManager.Defaults.speedPresets
            if let index = speeds.firstIndex(of: model.speed) {
                let nextIndex = (index + 1) % speeds.count
                model.setSpeed(speeds[nextIndex])
            } else {
                model.setSpeed(1.0)
            }
        } label: {
            Text(speedLabel)
                .customFont(.headline)
                .frame(minWidth: 44, minHeight: 44)
        }
        .foregroundStyle(model.speed != 1.0 ? (model.artworkAccentColor ?? .accentColor) : .secondary)
        .accessibilityLabel(Text("Playback speed"))
        .accessibilityValue(Text(speedLabel))
        .onChange(of: model.speed) { _, newSpeed in
            UIAccessibility.post(notification: .announcement, argument: String(localized: "Speed \(newSpeed.formatted(.number.precision(.fractionLength(1))))×"))
        }
    }


    // MARK: - Sleep Timer

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
            HStack(spacing: 4) {
                Image(systemName: model.sleepTimerMode.isActive ? "moon.zzz.fill" : "moon.zzz")
                    .font(.title2)
                if case .minutes = model.sleepTimerMode {
                    SleepTimerCountdownView()
                } else if case .endOfChapter = model.sleepTimerMode {
                    Text("EOC")
                        .customFont(.caption2, weight: .semibold)
                        .foregroundStyle(model.artworkAccentColor ?? .accentColor)
                }
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .foregroundStyle(model.sleepTimerMode.isActive ? (model.artworkAccentColor ?? .accentColor) : .secondary)
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

    // MARK: - Timeline / View Toggle

    private var timelineButton: some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                switch model.selectedTab {
                case .nowPlaying:
                    model.selectedTab = .timeline
                case .timeline:
                    model.selectedTab = .read
                case .read:
                    model.selectedTab = .timeline
                }
            }
            Haptic.play(.medium)
        } label: {
            Image(systemName: "list.bullet")
                .font(.title2)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .foregroundStyle((model.selectedTab == .timeline || model.selectedTab == .read) ? (model.artworkAccentColor ?? .accentColor) : .secondary)
        .accessibilityLabel(Text("Toggle chapters list"))
        .disabled(model.tracks.isEmpty)
    }

    // MARK: - Bookmark

    private var addBookmarkButton: some View {
        Button {
            if let draft = model.bookmarkDraftAtCurrentTime() {
                onCreateBookmark?(draft)
                Haptic.play(.medium)
            }
        } label: {
            Image(systemName: "bookmark.fill")
                .font(.title2)
                .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .foregroundStyle(.secondary)
        .accessibilityLabel(Text("Add bookmark at current time"))
        .disabled(model.tracks.isEmpty)
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
        .disabled(model.tracks.isEmpty)
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

private struct SleepTimerCountdownView: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        if model.sleepTimerRemainingSeconds > 0 {
            Text(sleepTimerCountdownText(model.sleepTimerRemainingSeconds))
                .customFont(.caption2, weight: .semibold)
                .foregroundStyle(model.artworkAccentColor ?? .accentColor)
                .monospacedDigit()
        }
    }
}
