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
}

/// The single timer home: a bare moon glyph when no timer is armed
/// (inactive = bare glyph), a tinted chip with moon + countdown when armed
/// (active = filled chip). Tapping opens the arming/cancel menu either way.
struct SleepTimerPill: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        Menu {
            menuItems
        } label: {
            if let label = SleepTimerPillState.labelText(mode: model.sleepTimerMode, remainingSeconds: model.sleepTimerRemainingSeconds) {
                HStack(spacing: 6) {
                    Image(systemName: "moon.zzz.fill")
                        .font(.subheadline.bold())
                    Text(label)
                        .font(.subheadline.monospacedDigit().bold())
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(model.coverTheme.chip, in: Capsule())
                .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                .foregroundStyle(model.artworkAccentColor ?? Color.accentColor)
            } else {
                Image(systemName: "moon.zzz")
                    .font(.body.bold())
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityLabel(Text("Sleep Timer"))
        .accessibilityValue(Text(accessibilityValue))
    }

    @ViewBuilder
    private var menuItems: some View {
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
    }

    private var accessibilityValue: String {
        switch model.sleepTimerMode {
        case .off: return String(localized: "Off")
        case .minutes(let m):
            return String(localized: "\(m) minutes, \(model.sleepTimerRemainingSeconds) seconds remaining")
        case .endOfChapter: return String(localized: "End of Chapter")
        }
    }
}
