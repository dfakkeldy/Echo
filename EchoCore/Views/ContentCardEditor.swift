import SwiftUI

struct ContentCardEditor: View {
    @Environment(\.dismiss) private var dismiss
    let card: ContentCard

    @State private var text: String
    @State private var title: String

    init(card: ContentCard) {
        self.card = card
        _text = State(initialValue: card.cardType == .note || card.cardType == .transcription ? card.title : "")
        _title = State(initialValue: card.cardType == .bookmark ? card.title : "")
    }

    var body: some View {
        NavigationStack {
            Form {
                switch card.cardType {
                case .note, .transcription:
                    Section("Text") {
                        TextEditor(text: $text)
                            .frame(minHeight: 120)
                            .font(.body)
                    }
                case .bookmark:
                    Section("Title") {
                        TextField("Bookmark Title", text: $title)
                    }
                    Section("Note") {
                        TextEditor(text: $text)
                            .frame(minHeight: 100)
                            .font(.body)
                    }
                case .flashcard, .playbackSession, .plannedSession,
                     .voiceMemo, .chapterTransition, .imageAsset:
                    ContentUnavailableView(
                        "Not Editable",
                        systemImage: "lock",
                        description: Text("This item type cannot be edited.")
                    )
                }
            }
            .navigationTitle("Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
