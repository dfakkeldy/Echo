// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct StudySessionView: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: StudySessionViewModel

    var body: some View {
        NavigationStack {
            VStack {
                if viewModel.isComplete {
                    ContentUnavailableView(
                        "All Done",
                        systemImage: "checkmark.circle.fill",
                        description: Text("You've finished today's study queue.")
                    )
                } else if let entry = viewModel.currentEntry {
                    StudyProgressHeader(progress: viewModel.progress)
                    Spacer(minLength: 16)
                    StudySessionCardView(entry: entry, viewModel: viewModel)
                        .id(entry.id)
                    Spacer(minLength: 16)
                }
            }
            .navigationTitle("Study")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .alert(
                "Study Error",
                isPresented: Binding(
                    get: { viewModel.errorMessage != nil },
                    set: { if !$0 { viewModel.errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
        }
    }
}

private struct StudyProgressHeader: View {
    let progress: (current: Int, total: Int)

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Card \(progress.current) of \(progress.total)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            ProgressView(
                value: Double(progress.current),
                total: Double(max(1, progress.total))
            )
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }
}

private struct StudySessionCardView: View {
    let entry: StudyQueueEntry
    @Bindable var viewModel: StudySessionViewModel

    var body: some View {
        if entry.flashcard.cardType == StudyFlashcardType.listeningAssignment
            || entry.flashcard.cardType == StudyFlashcardType.imageAssignment {
            StudyAssignmentCardView(
                entry: entry,
                isRevealed: viewModel.isRevealed,
                onPlay: { viewModel.requestPlayCurrentAssignment() },
                onReveal: { viewModel.reveal() },
                onGrade: { viewModel.gradeCurrent($0) }
            )
        } else {
            FlashcardReviewCard(
                frontText: entry.flashcard.frontText,
                backText: entry.flashcard.backText,
                onGrade: { grade in
                    if let reviewGrade = ReviewGrade(rawValue: grade) {
                        viewModel.gradeCurrent(reviewGrade)
                    }
                }
            )
        }
    }
}
