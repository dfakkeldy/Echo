import SwiftUI

// MARK: - Constants

private enum SleepTimerPresets {
    /// Sleep timer values cycled through on long-press (in minutes).
    static let values: [Int] = [15, 30, 45, 60]
}

extension View {
    @ViewBuilder
    func phoneLongPressGesture(action: WatchAction, model: PlayerModel) -> some View {
        if action != .empty {
            self.simultaneousGesture(
                LongPressGesture(minimumDuration: 0.5)
                    .onEnded { _ in
                        Haptic.play(.medium)
                        executeAction(action, model: model)
                    }
            )
        } else {
            self
        }
    }
}

private func executeAction(_ action: WatchAction, model: PlayerModel) {
    switch action {
    case .playPause:
        model.togglePlayPause()
    case .skipBackward:
        _ = model.skipBackward30()
    case .skipForward:
        _ = model.skipForward30()
    case .previousTrack:
        _ = model.skipBackwardNavigation()
    case .nextTrack:
        _ = model.skipForwardNavigation()
    case .previousSection:
        model.previousSectionOrRestart()
    case .nextSection:
        model.nextSection()
    case .loopMode:
        model.cycleLoopMode()
    case .speed:
        let speeds = SettingsManager.Defaults.speedPresets
        if let index = speeds.firstIndex(of: model.speed) {
            let nextIndex = (index + 1) % speeds.count
            model.setSpeed(speeds[nextIndex])
        } else {
            model.setSpeed(1.0)
        }
    case .sleepTimer:
        let presets = SleepTimerPresets.values
        switch model.sleepTimerMode {
        case .off: model.setSleepTimer(.minutes(presets[0]))
        case .minutes(let m) where m == presets[0]: model.setSleepTimer(.minutes(presets[1]))
        case .minutes(let m) where m == presets[1]: model.setSleepTimer(.minutes(presets[2]))
        case .minutes(let m) where m == presets[2]: model.setSleepTimer(.minutes(presets[3]))
        case .minutes(let m) where m == presets[3]: model.setSleepTimer(.endOfChapter)
        case .minutes: model.setSleepTimer(.minutes(presets[0]))
        case .endOfChapter: model.cancelSleepTimer()
        }
    case .bookmark:
        if let draft = model.bookmarkDraftAtCurrentTime() {
            model.activeBookmarkDraft = draft
        }
    case .empty:
        break
    }
}

struct TransportButton<Content: View>: View {
    let tapAction: () -> Void
    let longPressAction: WatchAction
    let model: PlayerModel
    @ViewBuilder let content: () -> Content

    @State private var isPressed = false

    var body: some View {
        if longPressAction != .empty {
            Button(action: {}) {
                content()
            }
            .buttonStyle(TransportPrimitiveButtonStyle(
                tapAction: tapAction,
                longPressAction: longPressAction,
                model: model,
                isPressed: $isPressed
            ))
        } else {
            Button(action: tapAction) {
                content()
            }
        }
    }
}

struct TransportPrimitiveButtonStyle: PrimitiveButtonStyle {
    let tapAction: () -> Void
    let longPressAction: WatchAction
    let model: PlayerModel
    @Binding var isPressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(Color.accentColor)
            .opacity(isPressed ? 0.5 : 1.0)
            .contentShape(Rectangle())
            .onTapGesture {
                configuration.trigger()
                tapAction()
                isPressed = false
            }
            .onLongPressGesture(
                minimumDuration: 0.5,
                perform: {
                    configuration.trigger()
                    Haptic.play(.medium)
                    executeAction(longPressAction, model: model)
                    isPressed = false
                },
                onPressingChanged: { pressing in
                    isPressed = pressing
                }
            )
    }
}
