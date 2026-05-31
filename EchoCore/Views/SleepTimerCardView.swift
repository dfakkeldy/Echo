import SwiftUI

struct SleepTimerCardView: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Sleep", systemImage: "moon.zzz")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(label)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundStyle(model.sleepTimerMode.isActive ? .orange : .secondary)

            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(width: 120)
        .background(.orange.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var label: String {
        switch model.sleepTimerMode {
        case .off:
            return "Off"
        case .endOfChapter:
            return "End of Ch."
        case .minutes(let total):
            let remaining = model.sleepTimerRemainingSeconds
            guard remaining > 0 else { return "\(total)m" }
            let min = remaining / 60
            let sec = remaining % 60
            return String(format: "%d:%02d", min, sec)
        }
    }

    private var caption: String {
        switch model.sleepTimerMode {
        case .off:
            "Sleep Timer"
        case .endOfChapter:
            "Sleep Timer"
        case .minutes:
            "remaining"
        }
    }
}
