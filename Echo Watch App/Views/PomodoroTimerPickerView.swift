import SwiftUI

struct PomodoroTimerPickerView: View {
    let viewModel: WatchViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedHours: Int = 0
    @State private var selectedMinutes: Int = 25
    @State private var selectedSeconds: Int = 0

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Button(action: { dismiss() }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Color.white.opacity(0.12), in: .circle)
                }
                .buttonStyle(.plain)
                
                Spacer()
            }
            .padding(.horizontal, 4)
            .padding(.top, 4)

            Spacer()

            HStack(spacing: 4) {
                Picker("Hours", selection: $selectedHours) {
                    ForEach(0...23, id: \.self) { hour in
                        Text(String(format: "%02d", hour))
                            .tag(hour)
                    }
                }
                .pickerStyle(.wheel)

                Text(":")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.8))

                Picker("Minutes", selection: $selectedMinutes) {
                    ForEach(0...59, id: \.self) { minute in
                        Text(String(format: "%02d", minute))
                            .tag(minute)
                    }
                }
                .pickerStyle(.wheel)

                Text(":")
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.8))

                Picker("Seconds", selection: $selectedSeconds) {
                    ForEach(0...59, id: \.self) { second in
                        Text(String(format: "%02d", second))
                            .tag(second)
                    }
                }
                .pickerStyle(.wheel)
            }
            .tint(viewModel.artworkAccentColor ?? .green)
            .frame(height: 85)

            Spacer()

            Button {
                let totalSeconds = (selectedHours * 3600) + (selectedMinutes * 60) + selectedSeconds
                if totalSeconds > 0 {
                    viewModel.setPomodoroDuration(TimeInterval(totalSeconds))
                    viewModel.startPomodoro()
                }
                dismiss()
            } label: {
                Text("Start")
                    .font(.system(.body, design: .rounded))
                    .fontWeight(.semibold)
                    .foregroundStyle(.black)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color(white: 0.7), in: .capsule)
            }
            .buttonStyle(.plain)
            .disabled(selectedHours == 0 && selectedMinutes == 0 && selectedSeconds == 0)
            .opacity((selectedHours == 0 && selectedMinutes == 0 && selectedSeconds == 0) ? 0.5 : 1.0)
        }
        .padding(.horizontal)
        .padding(.bottom, 4)
        .onAppear {
            let totalSeconds = Int(viewModel.pomodoroDuration)
            selectedHours = totalSeconds / 3600
            selectedMinutes = (totalSeconds % 3600) / 60
            selectedSeconds = totalSeconds % 60
        }
    }
}

#Preview {
    PomodoroTimerPickerView(viewModel: WatchViewModel())
}
