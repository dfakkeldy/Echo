import SwiftUI

struct FlashcardReviewSession: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: DailyReviewViewModel

    var body: some View {
        NavigationStack {
            VStack {
                if viewModel.isComplete {
                    ContentUnavailableView(
                        "All Done",
                        systemImage: "checkmark.circle.fill",
                        description: Text("You've reviewed all due flashcards.")
                    )
                } else if let card = viewModel.currentCard {
                    HStack {
                        Text("Card \(viewModel.progress.current) of \(viewModel.progress.total)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                    ProgressView(value: Double(viewModel.progress.current), total: Double(viewModel.progress.total))
                        .padding(.horizontal, 20)

                    Spacer()

                    FlashcardReviewCard(
                        frontText: card.frontText,
                        backText: card.backText,
                        onGrade: { grade in
                            viewModel.gradeCard(grade)
                        }
                    )

                    Spacer()
                }
            }
            .navigationTitle("Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        viewModel.snippetPlayer?.stop()
                        dismiss()
                    }
                }
            }
        }
    }
}
