import SwiftUI

struct TimelineHeaderView: View {
    @Binding var timeScale: TimeScale
    @Binding var timelineMode: TimelineService.TimelineMode
    @Binding var isViewingMode: Bool

    let onRecenterNow: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Picker("Scale", selection: $timeScale) {
                ForEach(TimeScale.allCases) { scale in
                    Text(scale.label).tag(scale)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 200)

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
}
