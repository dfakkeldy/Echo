// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import GRDB

/// Cards in a deck: searchable list with edit shortcuts.
import os.log

struct DeckDetailView: View {
    @Environment(PlayerModel.self) private var model

    let deckID: String?
    let deckName: String

    @State private var cards: [Flashcard] = []
    @State private var searchText: String = ""
    private let logger = Logger(category: "DeckDetailView")

    @State private var filteredCards: [Flashcard] = []
    @State private var cardPendingEdit: Flashcard?

    /// Recomputes the filtered list when the search field or loaded cards change,
    /// rather than on every `body` evaluation (audit §8.2). Keeps
    /// `localizedStandardContains` for user-entered search text.
    private func applyFilter() {
        guard !searchText.isEmpty else {
            filteredCards = cards
            return
        }
        filteredCards = cards.filter {
            $0.frontText.localizedStandardContains(searchText) ||
            $0.backText.localizedStandardContains(searchText) ||
            ($0.tags?.localizedStandardContains(searchText) ?? false)
        }
    }

    var body: some View {
        Group {
            if cards.isEmpty {
                ContentUnavailableView("No Cards", systemImage: "rectangle.stack")
            } else {
                List(filteredCards) { card in
                    Button {
                        cardPendingEdit = card
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(card.frontText)
                                .font(.callout)
                                .lineLimit(3)
                            Text(card.backText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                            HStack {
                                if card.intervalDays > 0 {
                                    Text("Interval: \(card.intervalDays)d")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Text("Ease: \(card.easeFactor.formatted(.number.precision(.fractionLength(1))))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                if card.isEnabled {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                        .font(.caption)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle(deckName)
        .searchable(text: $searchText, prompt: "Search cards")
        .task { await load() }
        .onChange(of: searchText) { _, _ in applyFilter() }
        .sheet(item: $cardPendingEdit) { card in
            FlashcardCreationSheet(card: card) { _ in
                Task { await load() }
            }
        }
    }

    private func load() async {
        guard let db = model.databaseService else { return }
        do {
            cards = try await db.writer.read { db in
                if let deckID {
                    try Flashcard
                        .filter(Column("deck_id") == deckID)
                        .order(Column("created_at").desc)
                        .fetchAll(db)
                } else {
                    try Flashcard
                        .order(Column("created_at").desc)
                        .fetchAll(db)
                }
            }
        } catch {
            logger.error("Failed to load deck detail: \(error.localizedDescription)")
        }
        applyFilter()
    }
}
