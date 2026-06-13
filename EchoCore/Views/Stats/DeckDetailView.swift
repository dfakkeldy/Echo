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

    var filteredCards: [Flashcard] {
        if searchText.isEmpty { return cards }
        return cards.filter {
            $0.frontText.localizedCaseInsensitiveContains(searchText) ||
            $0.backText.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        Group {
            if cards.isEmpty {
                ContentUnavailableView("No Cards", systemImage: "rectangle.stack")
            } else {
                List(filteredCards, id: \.id) { card in
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
                            Text("Ease: \(String(format: "%.1f", card.easeFactor))")
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
            }
        }
        .navigationTitle(deckName)
        .searchable(text: $searchText, prompt: "Search cards")
        .task { await load() }
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
    }
}
