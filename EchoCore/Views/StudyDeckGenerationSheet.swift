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
                        if let progress = viewModel.progress {
                            ProgressView(
                                "Generating cards… (\(progress.done) of \(progress.total))",
                                value: Double(progress.done),
                                total: Double(progress.total)
                            )
                        } else {
                            ProgressView("Generating Study Deck")
                        }
                    }
                } else if viewModel.noProviderConfigured {
                    Section {
                        ContentUnavailableView(
                            "No AI Provider Configured",
                            systemImage: "sparkles",
                            description: Text(
                                "Add a provider token under Settings > AI Card Generation, or enable Apple Intelligence for on-device generation."
                            )
                        )
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

                if viewModel.duplicatesSkipped > 0 {
                    Section {
                        Label(
                            "\(viewModel.duplicatesSkipped) duplicates skipped",
                            systemImage: "rectangle.on.rectangle.slash"
                        )
                        .foregroundStyle(.secondary)
                    }
                }

                if viewModel.acceptedCount > 0 {
                    Section {
                        Label(
                            "\(viewModel.acceptedCount) cards accepted",
                            systemImage: "checkmark.circle.fill"
                        )
                        .foregroundStyle(.green)
                        if let summary = viewModel.acceptedSummaryText {
                            Text(summary)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Generate Study Deck")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.cancelLoad()
                        dismiss()
                    }
                }
                ToolbarItemGroup(placement: .confirmationAction) {
                    Button("Accept All") {
                        if viewModel.acceptAll() {
                            dismiss()
                        }
                    }
                    .disabled(!viewModel.canAcceptAll)

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
            .onDisappear {
                viewModel.cancelLoad()
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
        ForEach(viewModel.chapterGroups) { group in
            Section {
                Button {
                    viewModel.toggleChapter(group)
                } label: {
                    Label(
                        chapterToggleTitle(for: group),
                        systemImage: chapterIsSelected(group) ? "checkmark.circle.fill" : "circle"
                    )
                }

                ForEach(group.cards) { card in
                    StudyDeckDraftCardRow(card: card, viewModel: viewModel)
                }
            } header: {
                Text(group.title)
            } footer: {
                Text("\(selectedCount(in: group)) of \(group.cards.count) selected")
            }
        }
    }

    private func selectedCount(in group: StudyDeckDraftChapterGroup) -> Int {
        group.cards.filter { viewModel.selectedCardIDs.contains($0.id) }.count
    }

    private func chapterIsSelected(_ group: StudyDeckDraftChapterGroup) -> Bool {
        selectedCount(in: group) == group.cards.count
    }

    private func chapterToggleTitle(for group: StudyDeckDraftChapterGroup) -> String {
        chapterIsSelected(group) ? "Deselect Chapter" : "Select Chapter"
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
