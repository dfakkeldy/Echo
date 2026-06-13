import SwiftUI
import GRDB

/// Right pane — transcript + notes in a vertical split view.
///
/// The top half shows the existing `TranscriptPane` for live transcription
/// segments. The bottom half lists per-book notes (Brain Dump style) with
/// inline editing, timestamp display, and create/delete support.
struct MacNotesPane: View {
    @Environment(MacPlayerModel.self) private var player
    @Environment(DatabaseService.self) private var dbService
    @Environment(TranscriptStore.self) private var transcriptStore
    @Environment(TranscriptionManager.self) private var transcriptionManager
    @State private var searchText = ""
    @State private var notes: [NoteRecord] = []
    @State private var newNoteText = ""
    @State private var isCreatingNote = false

    var body: some View {
        VSplitView {
            // Top: Transcript pane
            TranscriptPane(searchText: $searchText)
                .frame(minHeight: 150, idealHeight: 300)

            // Bottom: Notes list
            VStack(spacing: 0) {
                notesHeader

                Divider()

                if notes.isEmpty && !isCreatingNote {
                    Spacer()
                    ContentUnavailableView(
                        "No Notes",
                        systemImage: "note.text",
                        description: Text("Press ⌘N or tap below to add a note.")
                    )
                    Spacer()
                } else {
                    notesList
                }

                if isCreatingNote {
                    Divider()
                    newNoteField
                }
            }
            .frame(minHeight: 100, idealHeight: 200)
        }
        .frame(minWidth: 200)
        .task {
            await loadNotes()
        }
        .onChange(of: player.audiobookID) { _, _ in
            Task { await loadNotes() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestNewNote)) { _ in
            isCreatingNote = true
            newNoteText = ""
        }
        .onReceive(NotificationCenter.default.publisher(for: .requestExportTranscript)) { _ in
            guard let url = player.currentURL else { return }
            try? transcriptionManager.exportTranscript(for: url, segments: transcriptStore.segments(forHash: url.sha256Hash) ?? [])
        }
    }

    // MARK: - Notes Header

    private var notesHeader: some View {
        HStack {
            Text("Notes")
                .font(.headline)
            Spacer()
            Text("\(notes.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button {
                isCreatingNote.toggle()
                if isCreatingNote { newNoteText = "" }
            } label: {
                Image(systemName: isCreatingNote ? "minus.circle" : "plus.circle")
            }
            .buttonStyle(.borderless)
            .help(isCreatingNote ? "Cancel new note" : "Add a note")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Notes List

    private var notesList: some View {
        List {
            ForEach(notes, id: \.id) { note in
                NoteRowView(
                    note: note,
                    onDelete: { deleteNote(note) },
                    onUpdate: { updatedText in
                        updateNote(note, with: updatedText)
                    }
                )
            }
        }
        .listStyle(.plain)
    }

    // MARK: - New Note Field

    private var newNoteField: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Write a note…", text: $newNoteText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2...6)
                    .font(.body)

                HStack {
                    if player.hasMedia {
                        Text("at \(formatShortTime(player.currentTime))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Save") {
                        createNote()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(newNoteText.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(.separator, lineWidth: 0.5)
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Data

    private func loadNotes() async {
        guard let audiobookID = player.audiobookID else {
            notes = []
            return
        }
        do {
            notes = try await dbService.writer.read { db in
                try NoteRecord
                    .filter(Column("audiobook_id") == audiobookID)
                    .order(Column("media_timestamp"))
                    .fetchAll(db)
            }
        } catch {
            notes = []
        }
    }

    private func createNote() {
        let text = newNoteText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let audiobookID = player.audiobookID else { return }

        let now = ISO8601DateFormatter().string(from: Date())
        let note = NoteRecord(
            id: UUID().uuidString,
            audiobookID: audiobookID,
            text: text,
            mediaTimestamp: player.currentTime,
            realTimestamp: now,
            isEnabled: true,
            playlistPosition: nil,
            createdAt: now,
            modifiedAt: now
        )

        do {
            var mutableNote = note
            try dbService.writer.write { db in
                try mutableNote.insert(db)
            }
            newNoteText = ""
            isCreatingNote = false
            Task { await loadNotes() }
        } catch {
            // Silently ignore insert failures
        }
    }

    private func deleteNote(_ note: NoteRecord) {
        do {
            try dbService.writer.write { db in
                try NoteRecord.deleteOne(db, key: note.id)
            }
            Task { await loadNotes() }
        } catch {
            // Silently ignore delete failures
        }
    }

    private func updateNote(_ note: NoteRecord, with text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            deleteNote(note)
            return
        }

        var updated = note
        let now = ISO8601DateFormatter().string(from: Date())
        updated.text = trimmed
        updated.modifiedAt = now

        do {
            try dbService.writer.write { db in
                try updated.save(db)
            }
            Task { await loadNotes() }
        } catch {
            // Silently ignore update failures
        }
    }
}

// MARK: - Note Row

private struct NoteRowView: View {
    let note: NoteRecord
    let onDelete: () -> Void
    let onUpdate: (String) -> Void
    @State private var isEditing = false
    @State private var editText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isEditing {
                TextField("Edit note…", text: $editText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(2...6)
                    .font(.body)
                    .onSubmit {
                        onUpdate(editText)
                        isEditing = false
                    }

                HStack {
                    Button("Save") {
                        onUpdate(editText)
                        isEditing = false
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button("Cancel") {
                        isEditing = false
                    }
                    .controlSize(.small)
                }
            } else {
                Text(note.text)
                    .font(.body)
                    .textSelection(.enabled)
                    .lineLimit(4)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 12) {
                    Text(formatShortTime(note.mediaTimestamp))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)

                    Spacer()

                    Button("Edit") {
                        editText = note.text
                        isEditing = true
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)

                    Button("Delete", role: .destructive) {
                        onDelete()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Time formatting

private func formatShortTime(_ time: TimeInterval) -> String {
    let abs = abs(time)
    let hours = Int(abs) / 3600
    let minutes = (Int(abs) % 3600) / 60
    let seconds = Int(abs) % 60
    if hours > 0 {
        return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%d:%02d", minutes, seconds)
}
