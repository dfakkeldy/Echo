// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB
import SwiftUI
import os.log

/// Lists all flashcard decks with card counts and due counts.
struct DeckListView: View {
    @Environment(PlayerModel.self) private var model
    @State private var decks: [DeckSummary] = []
    @State private var isShowingNewDeckPrompt = false
    @State private var newDeckName = ""
    @State private var deckPendingRename: DeckSummary?
    @State private var renameDeckName = ""
    @State private var deckPendingDeletion: DeckSummary?
    @State private var creationError: String?
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
                        .swipeActions {
                            deckManagementActions(for: deck)
                        }
                        .contextMenu {
                            deckManagementActions(for: deck)
                        }
                    }
                }
            }
        }
        .navigationTitle("Decks")
        .task { await load() }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Deck", systemImage: "plus") {
                    newDeckName = ""
                    isShowingNewDeckPrompt = true
                }
            }
        }
        .alert("New Deck", isPresented: $isShowingNewDeckPrompt) {
            TextField("Deck Name", text: $newDeckName)
            Button("Cancel", role: .cancel) {
                newDeckName = ""
            }
            Button("Create") {
                createDeck()
            }
        }
        .alert("Rename Deck", isPresented: renameBinding) {
            TextField("Deck Name", text: $renameDeckName)
            Button("Cancel", role: .cancel) {
                deckPendingRename = nil
                renameDeckName = ""
            }
            Button("Save") {
                renameDeck()
            }
        }
        .alert(
            "Delete Deck",
            isPresented: deleteBinding,
            presenting: deckPendingDeletion
        ) { deck in
            Button("Delete", role: .destructive) {
                deleteDeck(deck)
            }
            Button("Cancel", role: .cancel) {
                deckPendingDeletion = nil
            }
        } message: { deck in
            Text("Cards in \(deck.name) will stay in your library without a deck.")
        }
        .alert(
            "Deck Change Failed",
            isPresented: Binding(get: { creationError != nil }, set: { if !$0 { creationError = nil } })
        ) {
            Button("OK") { creationError = nil }
        } message: {
            Text(creationError ?? "")
        }
    }

    @ViewBuilder
    private func deckManagementActions(for deck: DeckSummary) -> some View {
        Button("Rename", systemImage: "pencil") {
            deckPendingRename = deck
            renameDeckName = deck.name
        }
        Button(role: .destructive) {
            deckPendingDeletion = deck
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    private var renameBinding: Binding<Bool> {
        Binding(
            get: { deckPendingRename != nil },
            set: { isPresented in
                if !isPresented {
                    deckPendingRename = nil
                    renameDeckName = ""
                }
            }
        )
    }

    private var deleteBinding: Binding<Bool> {
        Binding(
            get: { deckPendingDeletion != nil },
            set: { isPresented in
                if !isPresented {
                    deckPendingDeletion = nil
                }
            }
        )
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

    private func createDeck() {
        guard let db = model.databaseService else {
            creationError = String(localized: "Could not create a deck because the database is unavailable.")
            return
        }

        do {
            _ = try DeckDAO(db: db.writer).findOrCreateManualDeck(named: newDeckName)
            newDeckName = ""
            Task { await load() }
        } catch {
            logger.error("Failed to create deck: \(error.localizedDescription)")
            creationError = error.localizedDescription
        }
    }

    private func renameDeck() {
        guard let db = model.databaseService else {
            creationError = String(localized: "Could not rename the deck because the database is unavailable.")
            return
        }
        guard let deck = deckPendingRename else { return }

        do {
            _ = try DeckDAO(db: db.writer).renameDeck(id: deck.id, to: renameDeckName)
            deckPendingRename = nil
            renameDeckName = ""
            Task { await load() }
        } catch {
            logger.error("Failed to rename deck: \(error.localizedDescription)")
            deckPendingRename = nil
            renameDeckName = ""
            creationError = error.localizedDescription
        }
    }

    private func deleteDeck(_ deck: DeckSummary) {
        guard let db = model.databaseService else {
            creationError = String(localized: "Could not delete the deck because the database is unavailable.")
            return
        }

        do {
            try DeckDAO(db: db.writer).deleteDeck(id: deck.id)
            deckPendingDeletion = nil
            Task { await load() }
        } catch {
            logger.error("Failed to delete deck: \(error.localizedDescription)")
            deckPendingDeletion = nil
            creationError = error.localizedDescription
        }
    }
}
