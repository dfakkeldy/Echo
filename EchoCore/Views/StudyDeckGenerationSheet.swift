// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct StudyDeckGenerationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var viewModel: StudyDeckGenerationViewModel

    var body: some View {
        NavigationStack {
            Form {
                if viewModel.isLoading {
                    Section {
                        ProgressView("Generating Study Deck")
                    }
                } else if viewModel.cards.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "No Eligible Blocks",
                            systemImage: "rectangle.stack.badge.questionmark",
                            description: Text(
                                "This book does not have visible EPUB text blocks for a study deck."
                            )
                        )
                    }
                } else {
                    StudyDeckDraftCardsSection(viewModel: viewModel)
                }

                if viewModel.acceptedCount > 0 {
                    Section {
                        Label(
                            "\(viewModel.acceptedCount) cards accepted",
                            systemImage: "checkmark.circle.fill"
                        )
                        .foregroundStyle(.green)
                    }
                }
            }
            .navigationTitle("Generate Study Deck")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(viewModel.isAccepting ? "Accepting" : "Accept") {
                        if viewModel.accept() {
                            dismiss()
                        }
                    }
                    .disabled(!viewModel.canAccept)
                }
            }
            .alert("Study Deck Error", isPresented: $viewModel.isShowingError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.errorMessage ?? "")
            }
            .task {
                await viewModel.load()
            }
        }
    }
}

private struct StudyDeckDraftCardsSection: View {
    @Bindable var viewModel: StudyDeckGenerationViewModel

    var body: some View {
        Section {
            ForEach(viewModel.cards) { card in
                StudyDeckDraftCardRow(card: card, viewModel: viewModel)
            }
        } header: {
            Text("Draft Cards")
        } footer: {
            Text("\(viewModel.selectedCardCount) of \(viewModel.cards.count) selected")
        }
    }
}

private struct StudyDeckDraftCardRow: View {
    let card: GeneratedStudyDeckCardDraft
    @Bindable var viewModel: StudyDeckGenerationViewModel

    var body: some View {
        let isSelected = viewModel.selectedCardIDs.contains(card.id)

        Button {
            viewModel.toggleCard(card)
        } label: {
            HStack(alignment: .top) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .imageScale(.large)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)

                VStack(alignment: .leading) {
                    Text(card.frontText)
                        .foregroundStyle(.primary)
                    Text(card.backText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Label(card.sourceBlockID, systemImage: "link")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Spacer()
            }
        }
        .buttonStyle(.plain)
        .accessibilityValue(Text(isSelected ? "Included" : "Excluded"))
    }
}
