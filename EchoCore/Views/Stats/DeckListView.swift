// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB
import SwiftUI
import UniformTypeIdentifiers
import os.log

/// Lists all flashcard decks with card counts and due counts.
struct DeckListView: View {
    @Environment(PlayerModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var snapshot = DeckLibrarySnapshot.empty
    @State private var isShowingNewDeckPrompt = false
    @State private var newDeckName = ""
    @State private var deckPendingRename: DeckSummary?
    @State private var renameDeckName = ""
    @State private var deckPendingDeletion: DeckSummary?
    @State private var creationError: String?
    @State private var showingDeckImporter = false
    @State private var importAlert: (title: String, message: String)?
    private let logger = Logger(category: "DeckListView")

    var body: some View {
        Group {
            if snapshot.isEmpty {
                emptyState
            } else {
                deckList
            }
        }
        .navigationTitle("Decks")
        .task { await load() }
        .toolbar {
            // Same exit as Card Inbox.
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
            // The empty state's Import Deck button is the one door while
            // there are no decks; "+" joins once a deck exists.
            if !snapshot.isEmpty {
                ToolbarItem(placement: .primaryAction) {
                    Button("New Deck", systemImage: "plus") {
                        newDeckName = ""
                        isShowingNewDeckPrompt = true
                    }
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
        .fileImporter(
            isPresented: $showingDeckImporter,
            allowedContentTypes: [.folder, .json],
            allowsMultipleSelection: false
        ) { result in
            importAlert = SettingsView.deckImportAlert(for: result, db: model.databaseService)
            Task { await load() }
        }
        .alert(
            importAlert?.title ?? "",
            isPresented: importAlertBinding
        ) {
            Button("OK") { importAlert = nil }
        } message: {
            Text(importAlert?.message ?? "")
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


    // MARK: - Content
    // Split out of `body`: one expression holding both states plus every
    // alert and importer exceeded the type checker's time limit on CI.

    private var emptyState: some View {
        // One primary door: the same deck import Settings offers.
        ContentUnavailableView {
            Label("No decks yet", systemImage: "rectangle.stack")
        } description: {
            Text("Import a deck, or make cards from a book in the player.")
        } actions: {
            Button("Import Deck", systemImage: "square.and.arrow.down") {
                showingDeckImporter = true
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.databaseService == nil)
        }
    }

    private var deckList: some View {
        List {
            // "All Cards" pseudo-deck
            NavigationLink {
                DeckDetailView(scope: .all, deckName: "All Cards")
            } label: {
                countRow(
                    title: Text("All Cards"),
                    count: Text("^[\(snapshot.totalCardCount) card](inflect: true)"),
                    due: snapshot.totalDueCount)
            }

            if snapshot.unassignedCardCount > 0 {
                NavigationLink {
                    DeckDetailView(scope: .unassigned, deckName: "Unassigned")
                } label: {
                    countRow(
                        title: Text("Unassigned"),
                        count: Text("^[\(snapshot.unassignedCardCount) card](inflect: true)"),
                        due: snapshot.unassignedDueCount)
                }
            }

            ForEach(snapshot.namedDecks) { deck in
                namedDeckRow(deck)
            }
        }
    }

    private func namedDeckRow(_ deck: DeckSummary) -> some View {
        NavigationLink {
            DeckDetailView(scope: .deck(id: deck.id), deckName: deck.name)
        } label: {
            countRow(title: Text(deck.name), count: Text("\(deck.cardCount)"), due: deck.dueCount)
        }
        .swipeActions {
            deckManagementActions(for: deck)
        }
        .contextMenu {
            deckManagementActions(for: deck)
        }
    }

    private func countRow(title: Text, count: Text, due: Int) -> some View {
        HStack {
            title
            Spacer()
            count
                .foregroundStyle(.secondary)
            if due > 0 {
                Text("\(due) due")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
    }

    private var importAlertBinding: Binding<Bool> {
        Binding(
            get: { importAlert != nil },
            set: { if !$0 { importAlert = nil } }
        )
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
