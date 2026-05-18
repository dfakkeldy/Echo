import SwiftUI

struct FlashcardReviewSession: View {
    @Environment(\.dismiss) private var dismiss
    let cards: [Flashcard]
    let onGrade: (Flashcard, Int) -> Void

    @State private var currentIndex = 0

    var body: some View {
        NavigationStack {
            VStack {
                if currentIndex < cards.count {
                    let card = cards[currentIndex]

                    // Progress
                    HStack {
                        Text("Card \(currentIndex + 1) of \(cards.count)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                    ProgressView(value: Double(currentIndex), total: Double(cards.count))
                        .padding(.horizontal, 20)

                    Spacer()

                    FlashcardReviewCard(
                        frontText: card.frontText,
                        backText: card.backText,
                        onGrade: { grade in
                            onGrade(cards[currentIndex], grade)
                            if currentIndex < cards.count - 1 {
                                withAnimation {
                                    currentIndex += 1
                                }
                            } else {
                                dismiss()
                            }
                        }
                    )

                    Spacer()
                } else {
                    ContentUnavailableView(
                        "All Done",
                        systemImage: "checkmark.circle.fill",
                        description: Text("You've reviewed all due flashcards.")
                    )
                }
            }
            .navigationTitle("Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
