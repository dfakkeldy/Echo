// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct PomodoroButton: View {
    let viewModel: WatchViewModel
    let controlSize: CGFloat
    var ringSize: CGFloat? = nil
    var isPrimaryActionEnabled = false
    let onLongPress: () -> Void

    private var activeRingSize: CGFloat {
        ringSize ?? controlSize
    }

    private var strokeWidth: CGFloat {
        WatchProgressRingMetrics.pomodoroLineWidth(hasSeparateRing: ringSize != nil)
    }

    private var ringProgress: Double {
        guard viewModel.pomodoroDuration.isFinite,
            viewModel.pomodoroDuration > 0,
            viewModel.pomodoroRemaining.isFinite
        else {
            return 0
        }
        return min(1, max(0, viewModel.pomodoroRemaining / viewModel.pomodoroDuration))
    }

    private var presentation: PomodoroTimePresentation {
        PomodoroTimePresentation.make(remaining: viewModel.pomodoroRemaining)
    }

    var body: some View {
        Button {
            viewModel.togglePomodoro()
        } label: {
            ZStack {
                WatchControlBackground(shape: Circle())
                    .frame(width: controlSize, height: controlSize)

                // Background track
                Circle()
                    .inset(by: strokeWidth / 2)
                    .stroke(Color.white.opacity(0.2), lineWidth: strokeWidth)
                    .frame(width: activeRingSize, height: activeRingSize)

                // Active progress track
                Circle()
                    .inset(by: strokeWidth / 2)
                    .trim(from: 0, to: ringProgress)
                    .stroke(
                        viewModel.pomodoroActive
                            ? (viewModel.artworkAccentColor ?? Color.accentColor) : Color.gray,
                        style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round)
                    )
                    .frame(width: activeRingSize, height: activeRingSize)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.2), value: ringProgress)

                // Fit inside the ring's opening, not over its stroke. The
                // bare number is the last resort when even the unit won't fit.
                ViewThatFits {
                    PomodoroDigits(presentation, textStyle: .headline)
                    PomodoroDigits(presentation, textStyle: .subheadline)
                    PomodoroDigits(presentation, textStyle: .caption)
                    PomodoroDigits(presentation, textStyle: .caption, showsUnit: false)
                }
                .foregroundStyle(.white)
                .padding(ringSize == nil ? strokeWidth : 0)
                .frame(width: controlSize, height: controlSize)
            }
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Pomodoro timer")
        .accessibilityValue(
            Text(presentation.accessibilityValue(isRunning: viewModel.pomodoroActive))
        )
        .accessibilityHint(
            Text(presentation.accessibilityHint(isRunning: viewModel.pomodoroActive))
        )
        .accessibilityAction(named: "Set duration") {
            onLongPress()
        }
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in
                    onLongPress()
                }
        )
        .modifier(WatchPrimaryActionModifier(isActive: isPrimaryActionEnabled))
    }
}

private struct PomodoroDigits: View {
    let presentation: PomodoroTimePresentation
    let textStyle: Font.TextStyle
    let showsUnit: Bool

    init(_ presentation: PomodoroTimePresentation, textStyle: Font.TextStyle, showsUnit: Bool = true) {
        self.presentation = presentation
        self.textStyle = textStyle
        self.showsUnit = showsUnit
    }

    var body: some View {
        // The unit letter is set smaller so the number stays the glanceable part.
        let number = Text(showsUnit ? presentation.unitNumber : presentation.digits)
            .font(.system(textStyle, design: .rounded, weight: .bold))
        let unit = Text(showsUnit ? presentation.unitSymbol : "")
            .font(.system(.caption2, design: .rounded, weight: .semibold))
        Text("\(number)\(unit)")
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }
}

#if DEBUG
    @MainActor
    private struct PomodoroButtonPreview: View {
        private let viewModel: WatchViewModel
        private let controlSize: CGFloat
        private let ringSize: CGFloat?

        init(
            controlSize: CGFloat,
            ringSize: CGFloat?,
            duration: TimeInterval,
            remaining: TimeInterval
        ) {
            let viewModel = WatchViewModel()
            viewModel.pomodoroDuration = duration
            viewModel.pomodoroRemaining = remaining
            viewModel.pomodoroActive = true
            self.viewModel = viewModel
            self.controlSize = controlSize
            self.ringSize = ringSize
        }

        var body: some View {
            PomodoroButton(
                viewModel: viewModel,
                controlSize: controlSize,
                ringSize: ringSize
            ) {}
        }
    }

    #Preview("Pomodoro size and unit matrix") {
        ScrollView {
            VStack(spacing: 12) {
                PomodoroButtonPreview(
                    controlSize: 38,
                    ringSize: nil,
                    duration: 2 * 3600,
                    remaining: 80 * 60
                )
                PomodoroButtonPreview(
                    controlSize: 40,
                    ringSize: nil,
                    duration: 25 * 60,
                    remaining: 25 * 60
                )
                PomodoroButtonPreview(
                    controlSize: 42,
                    ringSize: nil,
                    duration: 2 * 60,
                    remaining: 59
                )
                PomodoroButtonPreview(
                    controlSize: 40,
                    ringSize: 48,
                    duration: 25 * 60,
                    remaining: 12 * 60
                )
                PomodoroButtonPreview(
                    controlSize: 42,
                    ringSize: 52,
                    duration: 2 * 3600,
                    remaining: 2 * 3600
                )
            }
        }
    }

    #Preview("Pomodoro accessibility text") {
        PomodoroButtonPreview(
            controlSize: 38,
            ringSize: nil,
            duration: 25 * 60,
            remaining: 25 * 60
        )
        .environment(\.dynamicTypeSize, .accessibility3)
    }
#endif
