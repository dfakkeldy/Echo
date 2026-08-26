// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB
import SwiftUI
import os.log

/// Lists all flashcard decks with card counts and due counts.
struct DeckListView: View {
    @Environment(PlayerModel.self) private var model
    @State private var snapshot = DeckLibrarySnapshot.empty
    @State private var isShowingNewDeckPrompt = false
    @State private var newDeckName = ""
    @State private var deckPendingRename: DeckSummary?
    @State private var renameDeckName = ""
    @State private var deckPendingDeletion: DeckSummary?
    @State private var creationError: String?
    private let logger = Logger(category: "DeckListView")

    var body: some View {
        Group {
            if snapshot.isEmpty {
                ContentUnavailableView(
                    "No Decks",
                    systemImage: "rectangle.stack",
                    description: Text("Import a deck or create flashcards to get started.")
                )
            } else {
                List {
                    // "All Cards" pseudo-deck
                    NavigationLink {
                        DeckDetailView(scope: .all, deckName: "All Cards")
                    } label: {
                        HStack {
                            Text("All Cards")
                            Spacer()
                            Text("^[\(snapshot.totalCardCount) card](inflect: true)")
                                .foregroundStyle(.secondary)
                            if snapshot.totalDueCount > 0 {
                                Text("\(snapshot.totalDueCount) due")
                                    .foregroundStyle(.red)
                                    .font(.caption)
                            }
                        }
                    }

                    if snapshot.unassignedCardCount > 0 {
                        NavigationLink {
                            DeckDetailView(scope: .unassigned, deckName: "Unassigned")
                        } label: {
                            HStack {
                                Text("Unassigned")
                                Spacer()
                                Text("^[\(snapshot.unassignedCardCount) card](inflect: true)")
                                    .foregroundStyle(.secondary)
                                if snapshot.unassignedDueCount > 0 {
                                    Text("\(snapshot.unassignedDueCount) due")
                                        .foregroundStyle(.red)
                                        .font(.caption)
                                }
                            }
                        }
                    }

                    ForEach(snapshot.namedDecks) { deck in
                        NavigationLink {
                            DeckDetailView(scope: .deck(id: deck.id), deckName: deck.name)
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
            snapshot = try await db.writer.read { db in
                try DeckLibrarySnapshot.fetch(in: db)
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
