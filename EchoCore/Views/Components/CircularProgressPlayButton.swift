// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// A custom Play/Pause button capsule wrapped in a circular progress ring.
/// Double-tapping the ring/button area toggles between total book progress and chapter progress.
struct CircularProgressPlayButton: View {
    let isPlaying: Bool
    let totalProgress: Double
    let chapterProgress: Double
    let action: () -> Void
    var longPressAction: WatchAction = .empty
    let model: PlayerModel

    @State private var showChapterProgress = false
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var toastTask: Task<Void, Never>? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let currentProgress = showChapterProgress ? chapterProgress : totalProgress

        ZStack {
            // HUD Toast Indicator
            if showToast {
                Text(toastMessage)
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.black.opacity(0.75), in: Capsule())
                    .offset(y: -60)
                    .transition(.opacity.combined(with: .scale))
                    .zIndex(10)
            }

            // Progress Ring Background
            Circle()
                .stroke(model.coverTheme.chip, lineWidth: 3)
                .frame(width: 92, height: 92)

            // Progress Ring Fill
            Circle()
                .trim(from: 0, to: CGFloat(min(max(currentProgress, 0), 1)))
                .stroke(
                    Color.accentColor,
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .frame(width: 92, height: 92)
                .rotationEffect(.degrees(-90))
                .animation(reduceMotion ? nil : .smooth(duration: 0.35), value: currentProgress)

            // Play/Pause Hero Button
            TransportButton(
                tapAction: action,
                longPressAction: longPressAction,
                model: model
            ) {
                ZStack {
                    Circle()
                        .fill(model.artworkAccentColor ?? .accentColor)
                        .frame(width: 78, height: 78)

                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 36, weight: .bold))
                        .foregroundStyle(model.coverTheme.onAccent)
                }
            }
        }
        .contentShape(Circle())
        .onTapGesture(count: 2) {
            showChapterProgress.toggle()
            toastMessage = showChapterProgress ? String(localized: "Chapter Progress") : String(localized: "Book Progress")
            withAnimation(reduceMotion ? nil : .spring(duration: 0.25)) {
                showToast = true
            }
            Haptic.play(.medium)

            toastTask?.cancel()
            toastTask = Task {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) {
                    showToast = false
                }
            }
        }
    }
}
