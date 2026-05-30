import SwiftUI
import os.log

/// Sheet for creating a flashcard from transcript text.
/// Front side is pre-populated with the selected transcript segment.
struct FlashcardCreationSheet: View {
    @Environment(PlayerModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let sourceText: String
    let mediaTimestamp: TimeInterval

    @State private var frontText: String
    @State private var backText: String = ""

    init(sourceText: String, mediaTimestamp: TimeInterval) {
        self.sourceText = sourceText
        self.mediaTimestamp = mediaTimestamp
        _frontText = State(initialValue: sourceText)
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
            .navigationTitle("New Flashcard")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveFlashcard()
                        dismiss()
                    }
                    .disabled(frontText.isEmpty || backText.isEmpty)
                }
            }
        }
    }

    private func saveFlashcard() {
        guard let db = model.databaseService,
              let audiobookID = model.folderURL?.absoluteString else { return }

        let card = Flashcard(
            id: UUID().uuidString,
            audiobookID: audiobookID,
            frontText: frontText,
            backText: backText,
            mediaTimestamp: mediaTimestamp,
            endTimestamp: nil,
            triggerTiming: .manualOnly,
            nextReviewDate: Date().ISO8601Format(),
            intervalDays: 0,
            easeFactor: 2.5,
            repetitions: 0,
            lastReviewedAt: nil,
            lastGrade: nil,
            isEnabled: true,
            playlistPosition: nil,
            createdAt: Date().ISO8601Format(),
            modifiedAt: Date().ISO8601Format()
        )
        do {
            try FlashcardDAO(db: db.writer).insert(card)
        } catch {
            os_log(.error, "Failed to save flashcard: %{public}@", error.localizedDescription)
        }
    }
}
