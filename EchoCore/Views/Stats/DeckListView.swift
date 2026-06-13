import SwiftUI
import GRDB

/// Lists all flashcard decks with card counts and due counts.
import os.log

struct DeckListView: View {
    @Environment(PlayerModel.self) private var model
    @State private var decks: [DeckSummary] = []
    private let logger = Logger(category: "DeckListView")

    struct DeckSummary: Identifiable {
        let id: String
        let name: String
        let cardCount: Int
        let dueCount: Int
    }

    var body: some View {
        Group {
            if decks.isEmpty {
                ContentUnavailableView(
                    "No Decks",
                    systemImage: "rectangle.stack",
                    description: Text("Import a deck or create flashcards to get started.")
                )
            } else {
                List {
                    // "All Cards" pseudo-deck
                    let allDue = decks.reduce(0) { $0 + $1.dueCount }
                    let allTotal = decks.reduce(0) { $0 + $1.cardCount }
                    NavigationLink {
                        DeckDetailView(deckID: nil, deckName: "All Cards")
                    } label: {
                        HStack {
                            Text("All Cards")
                            Spacer()
                            Text("\(allTotal) cards")
                                .foregroundStyle(.secondary)
                            if allDue > 0 {
                                Text("\(allDue) due")
                                    .foregroundStyle(.red)
                                    .font(.caption)
                            }
                        }
                    }

                    ForEach(decks) { deck in
                        NavigationLink {
                            DeckDetailView(deckID: deck.id, deckName: deck.name)
                        } label: {
                            HStack {
                                Text(deck.name)
                                Spacer()
                                Text("\(deck.cardCount)")
                                    .foregroundStyle(.secondary)
                                if deck.dueCount > 0 {
                                    Text("\(deck.dueCount) due")
                                        .foregroundStyle(.red)
                                        .font(.caption)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Decks")
        .task { await load() }
    }

    private func load() async {
        guard let db = model.databaseService else { return }
        do {
            decks = try await db.writer.read { db in
                let rows = try Row.fetchCursor(db, sql: """
                    SELECT d.id, d.name,
                           COUNT(f.id) as card_count,
                           SUM(CASE WHEN f.next_review_date <= ? AND f.is_enabled = 1 THEN 1 ELSE 0 END) as due_count
                    FROM deck d
                    LEFT JOIN flashcard f ON f.deck_id = d.id
                    GROUP BY d.id, d.name
                    ORDER BY d.name
                    """, arguments: [Date()])
                var result: [DeckSummary] = []
                while let row = try rows.next() {
                    result.append(DeckSummary(
                        id: row["id"],
                        name: row["name"],
                        cardCount: row["card_count"] ?? 0,
                        dueCount: row["due_count"] ?? 0
                    ))
                }
                return result
            }
        } catch {
            logger.error("Failed to load decks: \(error.localizedDescription)")
        }
    }
}
