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
        } else if case .quizActive(let context) = coordinator.state,
                  let card = coordinator.currentQuizCard {
            VStack(spacing: 16) {
                quizHeader(context: context)
                #if os(macOS)
                    CheckpointInlineQuizCard(
                        frontText: card.frontText,
                        backText: card.backText,
                        onGrade: { coordinator.gradeQuizCard($0) }
                    )
                #else
                    FlashcardReviewCard(
                        frontText: card.frontText,
                        backText: card.backText,
                        onGrade: { grade in
                            if let reviewGrade = ReviewGrade(rawValue: grade) {
                                coordinator.gradeQuizCard(reviewGrade)
                            }
                        }
                    )
                #endif
                Button("Done for Now") { coordinator.dismissQuiz() }
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

    private func quizHeader(context: StudyCheckpointCoordinator.QuizContext) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "rectangle.stack.badge.questionmark")
                Text("Chapter Quiz")
                    .font(.caption)
                Spacer()
                Text("\(coordinator.quizPosition + 1) of \(coordinator.quizCards.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.secondary)
            Text(context.chapterTitle)
                .font(.headline)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        }
    }
}

#if os(macOS)
    private struct CheckpointInlineQuizCard: View {
        let frontText: String
        let backText: String
        let onGrade: (ReviewGrade) -> Void

        @State private var isRevealed = false

        var body: some View {
            VStack(spacing: 12) {
                Button {
                    isRevealed.toggle()
                } label: {
                    Text(isRevealed ? backText : frontText)
                        .font(isRevealed ? .body : .headline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, minHeight: 120)
                        .padding(16)
                        .background(.secondary.opacity(0.08), in: .rect(cornerRadius: 12))
                }
                .buttonStyle(.plain)

                if isRevealed {
                    HStack {
                        ForEach(ReviewGrade.allCases, id: \.self) { grade in
                            Button(grade.label) {
                                onGrade(grade)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
    }
#endif
