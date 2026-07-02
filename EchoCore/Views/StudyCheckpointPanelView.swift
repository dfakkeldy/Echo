// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// The checkpoint grade card: Again / Good (+ Skip when the chapter has no
/// user cards) with a countdown readout. Shared by the iOS in-player overlay
/// and the macOS player-window panel. The platform hosts decide presentation;
/// this view only renders the active context and renders nothing when idle.
struct StudyCheckpointPanelView: View {
    let coordinator: StudyCheckpointCoordinator

    var body: some View {
        if case .checkpointActive(let context) = coordinator.state {
            VStack(spacing: 16) {
                header(context: context)
                gradeButtons(context: context)
                Button("Not Now") { coordinator.cancel() }
                    .buttonStyle(.plain)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .background(.regularMaterial, in: .rect(cornerRadius: 16))
            .padding(.horizontal, 24)
            .accessibilityElement(children: .contain)
        }
    }

    private func header(context: StudyCheckpointCoordinator.Context) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.seal")
                Text("Chapter Checkpoint")
                    .font(.caption)
                Spacer()
                if coordinator.remainingSeconds > 0 {
                    Text("\(coordinator.remainingSeconds)")
                        .font(.caption.monospacedDigit())
                        .padding(6)
                        .background(.secondary.opacity(0.12), in: .circle)
                        .accessibilityLabel(
                            Text("\(coordinator.remainingSeconds) seconds left"))
                }
            }
            .foregroundStyle(.secondary)
            Text(context.chapterTitle)
                .font(.headline)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }

    private func gradeButtons(context: StudyCheckpointCoordinator.Context) -> some View {
        HStack(spacing: 8) {
            Button(ReviewGrade.again.label) { coordinator.resolve(.again) }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
            if context.skipEligible {
                Button("Skip") { coordinator.resolve(.skip) }
                    .buttonStyle(.bordered)
                    .frame(maxWidth: .infinity)
            }
            Button(ReviewGrade.good.label) { coordinator.resolve(.good) }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity)
        }
    }
}
