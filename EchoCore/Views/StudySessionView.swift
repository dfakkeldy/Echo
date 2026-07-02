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
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
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
                Button("OK", role: .cancel) {}
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
            || entry.flashcard.cardType == StudyFlashcardType.imageAssignment
            || entry.flashcard.cardType == StudyFlashcardType.vocabulary
        {
            StudyAssignmentCardView(
                entry: entry,
                isRevealed: viewModel.isRevealed,
                onPlay: { viewModel.requestPlayCurrentAssignment() },
                onReveal: { viewModel.reveal() },
                onGrade: { viewModel.gradeCurrent($0) },
                onSkip: viewModel.currentEntryIsSkipEligible()
                    ? { viewModel.skipCurrent() } : nil,
                needsAttention: viewModel.needsAttentionCardIDs.contains(entry.flashcard.id)
            )
        } else {
            #if os(macOS)
                StudyInlineReviewCard(
                    frontText: entry.flashcard.frontText,
                    backText: entry.flashcard.backText,
                    onGrade: { viewModel.gradeCurrent($0) }
                )
            #else
                FlashcardReviewCard(
                    frontText: entry.flashcard.frontText,
                    backText: entry.flashcard.backText,
                    onGrade: { grade in
                        if let reviewGrade = ReviewGrade(rawValue: grade) {
                            viewModel.gradeCurrent(reviewGrade)
                        }
                    }
                )
            #endif
        }
    }
}

private struct StudyInlineReviewCard: View {
    let frontText: String
    let backText: String
    let onGrade: (ReviewGrade) -> Void

    @State private var isRevealed = false

    var body: some View {
        VStack(spacing: 16) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isRevealed.toggle()
                }
            } label: {
                Text(isRevealed ? backText : frontText)
                    .font(isRevealed ? .body : .headline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, minHeight: 140)
                    .padding(20)
                    .background(
                        isRevealed
                            ? Color.accentColor.opacity(0.08) : Color.secondary.opacity(0.08),
                        in: .rect(cornerRadius: 12)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(isRevealed ? "Answer" : "Question"))
            .accessibilityValue(Text(isRevealed ? backText : frontText))
            .accessibilityHint(
                Text(isRevealed ? "Press to show question" : "Press to reveal answer"))

            if isRevealed {
                StudyInlineReviewGradeButtons(onGrade: onGrade)
            }
        }
        .padding(16)
    }
}

private struct StudyInlineReviewGradeButtons: View {
    let onGrade: (ReviewGrade) -> Void

    var body: some View {
        HStack(spacing: 8) {
            ForEach(ReviewGrade.allCases, id: \.self) { grade in
                Button(grade.label) {
                    onGrade(grade)
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
            }
        }
    }
}
