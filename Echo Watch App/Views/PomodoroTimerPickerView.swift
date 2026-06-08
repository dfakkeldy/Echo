import SwiftUI

struct PomodoroTimerPickerView: View {
    let viewModel: WatchViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedMinutes: Int = 25

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                Spacer()

                Picker(selection: $selectedMinutes, label: EmptyView()) {
                    ForEach(1...60, id: \.self) { min in
                        Text(String(localized: "\(min) min"))
                            .tag(min)
                    }
                }
                .pickerStyle(.wheel)
                .frame(maxHeight: 100)

                Spacer()

                Button {
                    viewModel.setPomodoroDuration(TimeInterval(selectedMinutes * 60))
                    dismiss()
                } label: {
                    Text("Set Duration")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(viewModel.artworkAccentColor ?? .accentColor)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
            .navigationTitle("Pomodoro")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                selectedMinutes = max(1, min(60, Int(viewModel.pomodoroDuration / 60)))
            }
        }
    }
}

#Preview {
    PomodoroTimerPickerView(viewModel: WatchViewModel())
}
