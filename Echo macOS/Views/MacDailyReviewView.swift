// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB
import SwiftUI

/// macOS daily flashcard review — the spaced-repetition study loop. A Mac-native
/// view over the shared, macOS-clean `DailyReviewViewModel` (the iOS
/// `FlashcardReviewSession` is not part of the macOS target). Reached via
/// Study ▸ Daily Review…. Snippet audio playback is intentionally omitted on
/// macOS (text review only); grading uses the same FSRS scheduler as iOS.
struct MacDailyReviewView: View {
    let db: DatabaseWriter
    let folderURL: URL?
    let reviewNotificationsEnabled: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var model: DailyReviewViewModel?

    var body: some View {
        VStack(spacing: 16) {
            header
            Divider()
            if let model {
                content(model)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 480, height: 380)
        .padding()
        .task {
            guard model == nil else { return }
            let vm = DailyReviewViewModel(
                db: db,
                folderURL: folderURL,
                reviewNotificationsEnabled: { reviewNotificationsEnabled })
            vm.loadDueCards()
            model = vm
        }
    }

    private var header: some View {
        HStack {
            Text("Daily Review").font(.headline)
            Spacer()
            if let model, !model.dueCards.isEmpty, !model.isComplete {
                Text("\(model.progress.current) / \(model.progress.total)")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    @ViewBuilder
    private func content(_ model: DailyReviewViewModel) -> some View {
        if model.dueCards.isEmpty {
            ContentUnavailableView(
                "All caught up",
                systemImage: "checkmark.circle",
                description: Text("No flashcards are due for review right now."))
        } else if model.isComplete {
            ContentUnavailableView(
                "Review complete",
                systemImage: "checkmark.seal",
                description: Text("You reviewed every due card. Nice work."))
        } else if let card = model.currentCard {
            VStack(spacing: 16) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(card.frontText)
                            .font(.title3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        if model.isRevealed {
                            Divider()
                            Text(card.backText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding()
                }
                .frame(maxWidth: .infinity)
                .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))

                if model.isRevealed {
                    HStack(spacing: 8) {
                        gradeButton("Again", grade: 0, key: "1", model: model)
                        gradeButton("Hard", grade: 1, key: "2", model: model)
                        gradeButton("Good", grade: 2, key: "3", model: model)
                        gradeButton("Easy", grade: 3, key: "4", model: model)
                    }
                } else {
                    Button("Reveal Answer") { model.reveal() }
                        .keyboardShortcut(.space, modifiers: [])
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private func gradeButton(
        _ title: String, grade: Int, key: Character, model: DailyReviewViewModel
    ) -> some View {
        // `gradeCard` grades with the FSRS scheduler AND advances to the next card.
        Button(title) { model.gradeCard(grade) }
            .keyboardShortcut(KeyEquivalent(key), modifiers: [])
            .frame(maxWidth: .infinity)
            .buttonStyle(.bordered)
    }
}
