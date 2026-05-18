import SwiftUI

struct TimelineHeaderView: View {
    @Binding var timeScale: TimeScale
    @Binding var timelineMode: TimelineService.TimelineMode
    @Binding var isViewingMode: Bool

    let onRecenterNow: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            scaleCycleButton

            Picker("Mode", selection: $timelineMode) {
                Text("Real Time").tag(TimelineService.TimelineMode.realTime)
                Text("Playlist").tag(TimelineService.TimelineMode.playlistTime)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 160)

            Spacer()

            Button {
                isViewingMode.toggle()
            } label: {
                Image(systemName: isViewingMode ? "eye" : "pencil")
            }
            .accessibilityLabel(isViewingMode ? "Viewing mode" : "Editing mode")

            Button {
                onRecenterNow()
            } label: {
                Label("Now", systemImage: "arrow.down.to.line")
            }
            .buttonStyle(.bordered)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - Scale cycle button

    private var scaleCycleButton: some View {
        Button {
            cycleScale()
        } label: {
            Label(timeScale.label, systemImage: "clock.arrow.2.circlepath")
                .font(.caption)
                .fontWeight(.medium)
        }
        .buttonStyle(.bordered)
        .contextMenu {
            ForEach(TimeScale.allCases) { scale in
                Button {
                    timeScale = scale
                } label: {
                    Label(scale.menuLabel, systemImage: scale == timeScale ? "checkmark" : "")
                }
            }
        }
    }

    private func cycleScale() {
        let all = TimeScale.allCases
        guard let idx = all.firstIndex(of: timeScale) else { return }
        timeScale = all[(idx + 1) % all.count]
    }
}
