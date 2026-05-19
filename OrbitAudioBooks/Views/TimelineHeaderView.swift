import SwiftUI

/// Header for the Timeline (playlist-time) tab — scale cycle and recenter only.
/// Mode switching and editing toggles live in the Planner tab header.
struct TimelineHeaderView: View {
    @Binding var scope: TimelineScope
    let onRecenterNow: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            scaleCycleButton

            Spacer()

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
            Label(scope.label, systemImage: "clock.arrow.2.circlepath")
                .font(.caption)
                .fontWeight(.medium)
        }
        .buttonStyle(.bordered)
        .contextMenu {
            ForEach(TimelineScope.allCases) { s in
                Button {
                    scope = s
                } label: {
                    Label(s.menuLabel, systemImage: s == scope ? "checkmark" : "")
                }
            }
        }
    }

    private func cycleScale() {
        let all = TimelineScope.allCases
        guard let idx = all.firstIndex(of: scope) else { return }
        scope = all[(idx + 1) % all.count]
    }
}
