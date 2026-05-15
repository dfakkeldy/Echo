import SwiftUI

struct VoiceMemoOverlayView: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "mic.fill")
                .foregroundStyle(.red)
            Text("Playing Voice Memo")
                .customFont(.headline)
            Button {
                model.stopVoiceMemo()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop voice memo")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.quaternary, lineWidth: 1))
        .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
        .transition(.opacity.combined(with: .scale))
        .overlay(alignment: .bottom) {
            ProgressView(value: model.voiceMemoProgress)
                .progressViewStyle(.linear)
                .frame(width: 180)
                .padding(.bottom, -22)
        }
    }
}
