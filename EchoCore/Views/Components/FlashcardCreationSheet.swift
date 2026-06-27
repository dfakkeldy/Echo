// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import os.log

/// Sheet for creating a flashcard from transcript text.
/// Front side is pre-populated with the selected transcript segment.
struct FlashcardCreationSheet: View {
    @Environment(PlayerModel.self) private var model
    @Environment(FreeTierGate.self) private var freeTierGate
    @Environment(\.dismiss) private var dismiss

    let sourceText: String
    let mediaTimestamp: TimeInterval
    let audiobookID: String?
    let endTimestamp: TimeInterval?
    let onSave: (String) -> Void
    private let existingCard: Flashcard?

    @State private var frontText: String
    @State private var backText: String = ""
    @State private var selectedDeckID: String?
    @State private var tagText: String
    @State private var decks: [Deck] = []
    @State private var saveError: String?
    private let logger = Logger(category: "FlashcardCreationSheet")

    init(
        sourceText: String,
        mediaTimestamp: TimeInterval,
        audiobookID: String? = nil,
        endTimestamp: TimeInterval? = nil,
        deckID: String? = nil,
        tags: String? = nil,
        onSave: @escaping (String) -> Void = { _ in }
    ) {
        self.sourceText = sourceText
        self.mediaTimestamp = mediaTimestamp
        self.audiobookID = audiobookID
        self.endTimestamp = endTimestamp
        self.onSave = onSave
        self.existingCard = nil
        _frontText = State(initialValue: sourceText)
        _selectedDeckID = State(initialValue: deckID)
        _tagText = State(initialValue: tags ?? "")
    }

    init(card: Flashcard, onSave: @escaping (String) -> Void = { _ in }) {
        self.sourceText = card.frontText
        self.mediaTimestamp = card.mediaTimestamp
        self.audiobookID = card.audiobookID
        self.endTimestamp = card.endTimestamp
        self.onSave = onSave
        self.existingCard = card
        _frontText = State(initialValue: card.frontText)
        _backText = State(initialValue: card.backText)
        _selectedDeckID = State(initialValue: card.deckID)
        _tagText = State(initialValue: card.tags ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Front (Question)") {
                    TextEditor(text: $frontText)
                        .frame(minHeight: 80)
                        .font(.body)
                }

                Section("Back (Answer)") {
                    TextEditor(text: $backText)
                        .frame(minHeight: 80)
                        .font(.body)
                }

                Section("Deck") {
                    Picker("Deck", selection: $selectedDeckID) {
                        Text("Unassigned").tag(Optional<String>.none)
                        ForEach(decks, id: \.id) { deck in
                            Text(deck.name).tag(Optional(deck.id))
                        }
                    }
                }

                Section("Tags") {
                    TextField("Tags", text: $tagText)
                }

                Section {
                    HStack {
                        Text("Position")
                        Spacer()
                        Text(formatHMS(mediaTimestamp))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            .navigationTitle(existingCard == nil ? "New Flashcard" : "Edit Flashcard")
            .navigationBarTitleDisplayMode(.inline)
            .task { loadDecks() }
            .alert(
                "Save Failed",
                isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })
            ) {
                Button("OK") { saveError = nil }
            } message: {
                Text(saveError ?? "")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if existingCard != nil || freeTierGate.canCreateFlashcards(adding: 1) {
                            if saveFlashcard() {
                                dismiss()
                            }
                        } else {
                            dismiss()
                            model.paywallContext = .flashcardCap
                            model.showPaywall = true
                        }
                    }
                    .disabled(frontText.isEmpty || backText.isEmpty)
                }
            }
        }
    }

    static func normalizedTags(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func loadDecks() {
        guard let db = model.databaseService else { return }
        do {
            decks = try DeckDAO(db: db.writer).all()
            if let selectedDeckID, !decks.contains(where: { $0.id == selectedDeckID }) {
                self.selectedDeckID = nil
            }
        } catch {
            logger.error("Failed to load decks for flashcard creation: \(error.localizedDescription)")
        }
    }

    private func saveFlashcard() -> Bool {
        guard let db = model.databaseService else {
            saveError = String(localized: "Could not save flashcard because the database is unavailable.")
            return false
        }
        guard let targetAudiobookID = audiobookID ?? model.folderURL?.absoluteString else {
            saveError = String(localized: "Could not save flashcard because no book is loaded.")
            return false
        }

        if var existingCard {
            existingCard.frontText = frontText
            existingCard.backText = backText
            existingCard.deckID = selectedDeckID
            existingCard.tags = Self.normalizedTags(from: tagText)
            existingCard.modifiedAt = Date().ISO8601Format()
            do {
                try FlashcardDAO(db: db.writer).update(existingCard)
                onSave(existingCard.id)
                return true
            } catch {
                os_log(.error, "Failed to update flashcard: %{public}@", error.localizedDescription)
                saveError = String(localized: "Could not save flashcard: \(error.localizedDescription)")
                return false
            }
        }

        let cardID = UUID().uuidString
        let card = Flashcard(
            id: cardID,
            audiobookID: targetAudiobookID,
            frontText: frontText,
            backText: backText,
            mediaTimestamp: mediaTimestamp,
            endTimestamp: endTimestamp,
            triggerTiming: .manualOnly,
            nextReviewDate: Date().ISO8601Format(),
            intervalDays: 0,
            easeFactor: 2.5,
            repetitions: 0,
            lastReviewedAt: nil,
            lastGrade: nil,
            isEnabled: true,
            deckID: selectedDeckID,
            tags: Self.normalizedTags(from: tagText),
            mediaJSON: nil,
            sourceBlockID: nil,
            playlistPosition: nil,
            createdAt: Date().ISO8601Format(),
            modifiedAt: Date().ISO8601Format()
        )
        do {
            try FlashcardDAO(db: db.writer).insert(card)
            onSave(cardID)
            ReviewPromptManager.shared.recordActivationEvent(.flashcardCreated)
            return true
        } catch {
            os_log(.error, "Failed to save flashcard: %{public}@", error.localizedDescription)
            saveError = String(localized: "Could not save flashcard: \(error.localizedDescription)")
            return false
        }
    }
}
