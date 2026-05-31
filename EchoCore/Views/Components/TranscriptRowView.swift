import SwiftUI

/// A read-only transcript segment row with HIG-compliant context menu for actions.
/// Tap seeks to the segment's start time. Long-press (context menu) offers
/// note creation, flashcard creation, or copy. Editing happens in presented sheets
/// to avoid gesture conflicts with the scroll view.
struct TranscriptRowView: View {
    @Environment(PlayerModel.self) private var player

    let segment: TranscriptionSegment
    let isActive: Bool
    let searchText: String

    @State private var showingNoteEditor = false
    @State private var showingFlashcardCreator = false

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(segment.text)
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isActive ? Color.accentColor.opacity(0.3) : Color.clear)
                )
        }
        .contentShape(.rect)
        .onTapGesture {
            player.seek(toSeconds: segment.startTime)
        }
        .contextMenu {
            Button {
                showingNoteEditor = true
            } label: {
                Label("Create Note", systemImage: "note.text")
            }

            Button {
                showingFlashcardCreator = true
            } label: {
                Label("Create Flashcard", systemImage: "rectangle.fill.on.rectangle.fill")
            }

            Button {
                UIPasteboard.general.string = segment.text
            } label: {
                Label("Copy Text", systemImage: "doc.on.doc")
            }
        }
        .sheet(isPresented: $showingNoteEditor) {
            NoteEditorView(preselectedTimestamp: segment.startTime)
        }
        .sheet(isPresented: $showingFlashcardCreator) {
            FlashcardCreationSheet(
                sourceText: segment.text,
                mediaTimestamp: segment.startTime
            )
        }
    }
}
