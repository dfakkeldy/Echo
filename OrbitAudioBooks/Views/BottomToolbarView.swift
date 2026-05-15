import SwiftUI

struct BottomToolbarView: View {
    @Environment(PlayerModel.self) private var model
    @Binding var showingPlaylist: Bool
    var onCreateBookmark: ((BookmarkDraft) -> Void)?

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                loopModeButton
                Spacer()
                speedButton
                Spacer()
                sleepTimerMenu
                Spacer()
                addBookmarkButton
                Spacer()
                playlistButton
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
        .background(.bar)
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
        .accessibilityLabel("Loop mode")
        .accessibilityValue({
            switch model.loopMode {
            case .off: return "Off"
            case .chapter: return "Chapter"
            case .bookmark: return "Bookmark"
            }
        }())
    }

    // MARK: - Speed

    private var speedButton: some View {
        Button {
            let speeds: [Float] = [1.0, 1.25, 1.5, 2.0, 10.0]
            if let index = speeds.firstIndex(of: model.speed) {
                let nextIndex = (index + 1) % speeds.count
                model.setSpeed(speeds[nextIndex])
            } else {
                model.setSpeed(1.0)
            }
        } label: {
            Text(String(format: "%gx", model.speed))
                .customFont(.headline)
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("Playback speed, \(String(format: "%g", model.speed)) times")
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
        .accessibilityLabel("Sleep Timer")
        .accessibilityValue({
            switch model.sleepTimerMode {
            case .off: return "Off"
            case .minutes(let m): return "\(m) minutes, \(model.sleepTimerRemainingSeconds) seconds remaining"
            case .endOfChapter: return "End of chapter"
            }
        }())
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
        .accessibilityLabel("Add bookmark at current time")
        .disabled(model.tracks.isEmpty)
    }

    // MARK: - Playlist

    private var playlistButton: some View {
        Button {
            showingPlaylist = true
        } label: {
            Image(systemName: "list.bullet")
                .font(.title2)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Playlist")
    }
}
