import SwiftUI

struct PomodoroButton: View {
    let viewModel: WatchViewModel
    let controlSize: CGFloat
    var ringSize: CGFloat? = nil
    let onLongPress: () -> Void

    private var activeRingSize: CGFloat {
        ringSize ?? controlSize
    }

    private var strokeWidth: CGFloat {
        ringSize != nil ? 4.5 : 3.5
    }

    private var ringProgress: Double {
        viewModel.pomodoroDuration > 0 ? (viewModel.pomodoroRemaining / viewModel.pomodoroDuration) : 0.0
    }

    private var timeString: String {
        let remaining = Int(viewModel.pomodoroRemaining)
        if remaining >= 3600 {
            let hours = remaining / 3600
            let mins = (remaining % 3600) / 60
            return String(format: "%02d:%02d", hours, mins)
        } else {
            let mins = remaining / 60
            let secs = remaining % 60
            return String(format: "%02d:%02d", mins, secs)
        }
    }

    var body: some View {
        Button {
            viewModel.togglePomodoro()
        } label: {
            ZStack {
                // Background track
                Circle()
                    .stroke(Color.white.opacity(0.2), lineWidth: strokeWidth)
                    .frame(width: activeRingSize, height: activeRingSize)

                // Active progress track
                Circle()
                    .trim(from: 0, to: ringProgress)
                    .stroke(
                        viewModel.pomodoroActive ? (viewModel.artworkAccentColor ?? Color.accentColor) : Color.gray,
                        style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round)
                    )
                    .frame(width: activeRingSize, height: activeRingSize)
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 0.2), value: ringProgress)

                // Text inside
                Text(timeString)
                    .font(.system(size: controlSize * 0.23, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(viewModel.pomodoroActive ? (viewModel.artworkAccentColor ?? Color.accentColor) : Color.white)
                    .frame(width: controlSize, height: controlSize)
                    .background {
                        WatchControlBackground(shape: Circle())
                    }
                    .clipShape(Circle())
            }
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5)
                .onEnded { _ in
                    onLongPress()
                }
        )
    }
}

#Preview {
    PomodoroButton(viewModel: WatchViewModel(), controlSize: 40) {}
}
