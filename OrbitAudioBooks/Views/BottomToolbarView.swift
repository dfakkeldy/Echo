import SwiftUI

struct BottomToolbarView: View {
    @Environment(PlayerModel.self) private var model
    var onCreateBookmark: ((BookmarkDraft) -> Void)?

    var body: some View {
        HStack {
            loopModeButton
            Spacer()
            speedButton
            Spacer()
            volumeBoostButton
            Spacer()
            sleepTimerMenu
            Spacer()
            addBookmarkButton
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 1))
        .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 5)
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    // MARK: - Loop Mode

    private var loopModeButton: some View {
        Button {
            model.cycleLoopMode()
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
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
        default:   return String(format: "%g×", model.speed)
        }
    }


    private var speedButton: some View {
        Button {
            let speeds: [Float] = [1.0, 1.25, 1.5, 2.0, 3.0]
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
        .accessibilityLabel(Text("Playback speed"))
        .accessibilityValue(Text(speedLabel))
        .onChange(of: model.speed) { _, newSpeed in
            UIAccessibility.post(notification: .announcement, argument: String(localized: "Speed \(String(format: "%g", newSpeed))×"))
        }
    }

    // MARK: - Volume Boost

    private var volumeBoostButton: some View {
        Button {
            model.setVolumeBoost(enabled: !model.isVolumeBoostEnabled)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        } label: {
            Image(systemName: model.isVolumeBoostEnabled ? "speaker.wave.3.fill" : "speaker.wave.3")
                .font(.title2)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Text("Volume Boost"))
        .accessibilityValue(Text(model.isVolumeBoostEnabled ? "On" : "Off"))
    }

    // MARK: - Sleep Timer

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
            HStack(spacing: 4) {
                Image(systemName: model.sleepTimerMode.isActive ? "moon.zzz.fill" : "moon.zzz")
                    .font(.title2)
                if case .minutes = model.sleepTimerMode,
                   model.sleepTimerRemainingSeconds > 0 {
                    Text(sleepTimerCountdownText(model.sleepTimerRemainingSeconds))
                        .customFont(.caption2, weight: .semibold)
                        .foregroundStyle(Color.accentColor)
                        .monospacedDigit()
                } else if case .endOfChapter = model.sleepTimerMode {
                    Text("EOC")
                        .customFont(.caption2, weight: .semibold)
                        .foregroundStyle(Color.accentColor)
                }
            }
            .frame(minWidth: 44, minHeight: 44)
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

    // MARK: - Bookmark

    private var addBookmarkButton: some View {
        Button {
            if let draft = model.bookmarkDraftAtCurrentTime() {
                onCreateBookmark?(draft)
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            }
        } label: {
            Image(systemName: "bookmark.fill")
                .font(.title2)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(Text("Add bookmark at current time"))
        .disabled(model.tracks.isEmpty)
    }
}
