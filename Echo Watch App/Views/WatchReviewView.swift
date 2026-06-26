// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Hands-free flashcard review view for Apple Watch. Uses Double Tap gesture
/// (handGestureShortcut) for Reveal/Good actions so the user can review cards
/// without touching the screen.
struct WatchReviewView: View {
    @Bindable var viewModel: WatchViewModel
    let isPrimaryActionEnabled: Bool

    @State private var currentIndex = 0
    @State private var isRevealed = false

    var body: some View {
        VStack(spacing: 8) {
            if currentIndex < viewModel.dueCards.count {
                let card = viewModel.dueCards[currentIndex]

                Text("\(currentIndex + 1) of \(viewModel.dueCards.count)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                ScrollView {
                    VStack(spacing: 12) {
                        Text(isRevealed ? card.backText : card.frontText)
                            .font(.body)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)

                        if isRevealed {
                            HStack(spacing: 8) {
                                gradeButton("Again", grade: 0, color: .red)
                                WatchReviewPrimaryActionButton(
                                    title: "Good",
                                    systemImage: "hand.thumbsup.fill",
                                    isPrimaryActionEnabled: isPrimaryActionEnabled
                                ) {
                                    gradeAndAdvance(grade: 3)
                                }
                                gradeButton("Easy", grade: 5, color: .blue)
                            }
                            .padding(.horizontal)
                        } else {
                            WatchReviewPrimaryActionButton(
                                title: "Reveal",
                                systemImage: "eye",
                                isPrimaryActionEnabled: isPrimaryActionEnabled
                            ) {
                                viewModel.playReviewRevealHaptic()
                                withAnimation {
                                    isRevealed = true
                                }
                            }
                            .padding(.horizontal)
                        }
                    }
                }
            } else {
                ContentUnavailableView(
                    "All Done",
                    systemImage: "checkmark.circle.fill",
                    description: Text("You've reviewed all due flashcards.")
                )
            }
        }
        .onAppear {
            currentIndex = 0
            isRevealed = false
        }
    }

    private func gradeAndAdvance(grade: Int) {
        guard currentIndex < viewModel.dueCards.count else { return }
        let cardID = viewModel.dueCards[currentIndex].id
        viewModel.gradeFlashcard(cardID: cardID, grade: grade)
        if currentIndex < viewModel.dueCards.count - 1 {
            currentIndex += 1
            isRevealed = false
        } else {
            currentIndex += 1
        }
    }

    @ViewBuilder
    private func gradeButton(_ label: String, grade: Int, color: Color) -> some View {
        Button {
            gradeAndAdvance(grade: grade)
        } label: {
            Text(label)
                .font(.caption)
                .frame(maxWidth: .infinity)
        }
        .tint(color)
    }
}

private struct WatchReviewPrimaryActionButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    let isPrimaryActionEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .frame(maxWidth: .infinity)
        }
        .handGestureShortcut(.primaryAction, isEnabled: isPrimaryActionEnabled)
    }
}
