import SwiftUI

struct TransportControlsView: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        HStack {
            Spacer()

            Button {
                let didJumpToBookmark = model.skipBackwardNavigation()
                UIImpactFeedbackGenerator(style: didJumpToBookmark ? .medium : .light).impactOccurred()
            } label: {
                Image(systemName: "backward.end.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 64, height: 64)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(model.chapters.count >= 2 ? Text("Previous chapter") : Text("Previous track"))

            Spacer()

            Button {
                let didJumpToBookmark = model.skipBackward30()
                UIImpactFeedbackGenerator(style: didJumpToBookmark ? .medium : .light).impactOccurred()
            } label: {
                Image(systemName: "gobackward.30")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(.primary)
                    .frame(width: 64, height: 64)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("Skip back 30 seconds"))

            Spacer()

            Button {
                model.togglePlayPause()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(.primary)
                    .frame(width: 76, height: 76)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(model.isPlaying ? Text("Pause") : Text("Play"))

            Spacer()

            Button {
                let didJumpToBookmark = model.skipForward30()
                UIImpactFeedbackGenerator(style: didJumpToBookmark ? .medium : .light).impactOccurred()
            } label: {
                Image(systemName: "goforward.30")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(.primary)
                    .frame(width: 64, height: 64)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(Text("Skip forward 30 seconds"))

            Spacer()

            Button {
                let didJumpToBookmark = model.skipForwardNavigation()
                UIImpactFeedbackGenerator(style: didJumpToBookmark ? .medium : .light).impactOccurred()
            } label: {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 64, height: 64)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(model.chapters.count >= 2 ? Text("Next chapter") : Text("Next track"))

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
    }
}
