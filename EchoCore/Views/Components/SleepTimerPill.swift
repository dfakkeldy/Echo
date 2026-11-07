// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Pure label logic for the top-of-player timer pill, kept separate from the
/// view so the mode → text mapping is unit-testable. Designed to grow a
/// pomodoro mode later ("2/4 · 18:42") in the same slot without changing the
/// pill's shape.
enum SleepTimerPillState {
    static func labelText(mode: SleepTimerMode, remainingSeconds: Int) -> String? {
        switch mode {
        case .off: return nil
        case .minutes: return sleepTimerCountdownText(remainingSeconds)
        case .endOfChapter: return "EOC"
        }
    }

    static func accessibilityValue(mode: SleepTimerMode, remainingSeconds: Int) -> String {
        switch mode {
        case .off:
            return String(localized: "Off")
        case .minutes(let minutes):
            return String(
                format: String(localized: "%lld minutes, %lld seconds remaining"),
                minutes,
                remainingSeconds
            )
        case .endOfChapter:
            return String(localized: "End of Chapter")
        }
    }

    static func activeStatusText(mode: SleepTimerMode, remainingSeconds: Int) -> String? {
        switch mode {
        case .off:
            return nil
        case .minutes:
            let countdown = sleepTimerCountdownText(remainingSeconds)
            return String(
                localized: "Remaining: \(countdown)",
                comment: "Sleep timer remaining countdown"
            )
        case .endOfChapter:
            return String(localized: "End of Chapter")
        }
    }
}

struct SleepTimerMenuContent: View {
    @Environment(PlayerModel.self) private var model
    var showsActiveStatus = false

    @ViewBuilder
    var body: some View {
        if showsActiveStatus,
            let status = SleepTimerPillState.activeStatusText(
                mode: model.sleepTimerMode,
                remainingSeconds: model.sleepTimerRemainingSeconds
            )
        {
            Button(action: {}) {
                Label(status, systemImage: "moon.zzz.fill")
            }
            .disabled(true)
            Divider()
        }

        // Plain text rows: the label already says the duration, so no icon
        // repeats it.
        option("15 Minutes", mode: .minutes(15))
        option("30 Minutes", mode: .minutes(30))
        option("45 Minutes", mode: .minutes(45))
        option("1 Hour", mode: .minutes(60))
        Divider()
        option("End of Chapter", mode: .endOfChapter)
        Divider()
        option("Off", mode: .off)
    }

    /// A menu Toggle renders the system checkmark, so the armed choice (or
    /// "Off" when nothing is armed) is the only row that looks different.
    private func option(_ title: LocalizedStringKey, mode: SleepTimerMode) -> some View {
        Toggle(
            title,
            isOn: Binding(
                get: { model.sleepTimerMode == mode },
                set: { _ in
                    if mode == .off {
                        model.cancelSleepTimer()
                    } else {
                        model.setSleepTimer(mode)
                    }
                    Haptic.play(.light)
                }
            )
        )
    }
}

/// The single timer home: a bare moon glyph when no timer is armed
/// (inactive = bare glyph), a tinted chip with moon + countdown when armed
/// (active = filled chip). Tapping opens the arming/cancel menu either way.
struct SleepTimerPill: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        Menu {
            SleepTimerMenuContent()
        } label: {
            if let label = SleepTimerPillState.labelText(
                mode: model.sleepTimerMode, remainingSeconds: model.sleepTimerRemainingSeconds)
            {
                HStack(spacing: 6) {
                    Image(systemName: "moon.zzz.fill")
                        .font(.subheadline.bold())
                    Text(label)
                        .font(.subheadline.monospacedDigit().bold())
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background {
                    Capsule()
                        .fill(model.coverTheme.chip)
                        .stroke(Color.white.opacity(0.15), lineWidth: 0.5)
                }
                .foregroundStyle(model.resolvedThemeTint ?? Color.accentColor)
            } else {
                Image(systemName: "moon.zzz")
                    .font(.body.bold())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    // Cover accent like the sibling header chips (was .secondary).
                    .foregroundStyle(model.resolvedThemeTint ?? Color.accentColor)
            }
        }
        .accessibilityLabel(Text("Sleep Timer"))
        .accessibilityValue(
            Text(
                SleepTimerPillState.accessibilityValue(
                    mode: model.sleepTimerMode,
                    remainingSeconds: model.sleepTimerRemainingSeconds
                )
            )
        )
    }
}
