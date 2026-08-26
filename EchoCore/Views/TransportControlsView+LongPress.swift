#if os(iOS)
// SPDX-License-Identifier: GPL-3.0-or-later
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
                        executeSecondaryAction(action, model: model)
                    }
            )
            .accessibilityAction(
                named: Text(secondaryAccessibilityActionName(for: action, model: model))
            ) {
                executeSecondaryAction(action, model: model)
            }
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
    case .markPassage:
        model.markPassageAtCurrentTime()
    case .pomodoro:
        break
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
            Button(action: tapAction) {
                content()
            }
            .buttonStyle(TransportPrimitiveButtonStyle(
                longPressAction: longPressAction,
                model: model,
                isPressed: $isPressed
            ))
            .accessibilityAction(
                named: Text(secondaryAccessibilityActionName(for: longPressAction, model: model))
            ) {
                executeSecondaryAction(longPressAction, model: model)
            }
        } else {
            Button(action: tapAction) {
                content()
            }
        }
    }
}

struct TransportPrimitiveButtonStyle: PrimitiveButtonStyle {
    let longPressAction: WatchAction
    let model: PlayerModel
    @Binding var isPressed: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(model.resolvedThemeTint ?? Color.accentColor)
            .opacity(isPressed ? 0.5 : 1.0)
            .contentShape(Rectangle())
            .onTapGesture {
                configuration.trigger()
                isPressed = false
            }
            .onLongPressGesture(
                minimumDuration: 0.5,
                perform: {
                    executeSecondaryAction(longPressAction, model: model)
                    isPressed = false
                },
                onPressingChanged: { pressing in
                    isPressed = pressing
                }
            )
    }
}

private func executeSecondaryAction(_ action: WatchAction, model: PlayerModel) {
    guard action != .empty else { return }
    Haptic.play(.medium)
    executeAction(action, model: model)
}

private func secondaryAccessibilityActionName(for action: WatchAction, model: PlayerModel) -> String {
    switch action {
    case .playPause:
        return model.isPlaying
            ? String(localized: "Secondary action: Pause")
            : String(localized: "Secondary action: Play")
    case .skipBackward:
        return String(localized: "Secondary action: Skip back")
    case .skipForward:
        return String(localized: "Secondary action: Skip forward")
    case .previousTrack:
        return String(localized: "Secondary action: Previous chapter or track")
    case .nextTrack:
        return String(localized: "Secondary action: Next chapter or track")
    case .previousSection:
        return String(localized: "Secondary action: Previous section")
    case .nextSection:
        return String(localized: "Secondary action: Next section")
    case .loopMode:
        return String(localized: "Secondary action: Change loop mode")
    case .speed:
        return String(localized: "Secondary action: Cycle playback speed")
    case .sleepTimer:
        return String(localized: "Secondary action: Cycle sleep timer")
    case .bookmark:
        return String(localized: "Secondary action: Add bookmark")
    case .markPassage:
        return String(localized: "Secondary action: Mark passage for later")
    case .pomodoro:
        return String(localized: "Secondary action: Pomodoro")
    case .empty:
        return String(localized: "Secondary action")
    }
}

#endif
