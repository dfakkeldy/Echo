// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import WatchKit

/// Hands-free flashcard review view for Apple Watch. Uses Double Tap gesture
/// (handGestureShortcut) for Reveal/Good actions so the user can review cards
/// without touching the screen.
struct WatchReviewView: View {
    @Bindable var viewModel: WatchViewModel

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
                                Button {
                                    gradeAndAdvance(grade: 3)
                                } label: {
                                    Label("Good", systemImage: "hand.thumbsup.fill")
                                        .font(.caption)
                                        .frame(maxWidth: .infinity)
                                }
                                .handGestureShortcut(.primaryAction)
                                gradeButton("Easy", grade: 5, color: .blue)
                            }
                            .padding(.horizontal)
                        } else {
                            Button {
                                WKInterfaceDevice.current().play(.click)
                                withAnimation {
                                    isRevealed = true
                                }
                            } label: {
                                Label("Reveal", systemImage: "eye")
                                    .font(.caption)
                                    .frame(maxWidth: .infinity)
                            }
                            .handGestureShortcut(.primaryAction)
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
        WKInterfaceDevice.current().play(.notification)
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
