import SwiftUI
import os.log

struct NoteEditorView: View {
    @Environment(PlayerModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    let preselectedTimestamp: TimeInterval?

    @State private var text: String = ""
    @State private var timestamp: TimeInterval
    @State private var saveError: String?

    init(preselectedTimestamp: TimeInterval? = nil) {
        self.preselectedTimestamp = preselectedTimestamp
        _timestamp = State(initialValue: preselectedTimestamp ?? 0)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Note") {
                    TextEditor(text: $text)
                        .frame(minHeight: 150)
                        .font(.body)
                }

                Section("Timestamp") {
                    HStack {
                        Text("Position")
                        Spacer()
                        Text(formatHMS(timestamp))
                            .foregroundStyle(.secondary)
                    }

                    Stepper("Adjust by 1 second", value: $timestamp, step: 1.0)
                        .labelsHidden()
                }
            }
            .navigationTitle("New Note")
            .navigationBarTitleDisplayMode(.inline)
            .alert("Save Failed", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
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
                        saveNote()
                        dismiss()
                    }
                }
            }
        }
    }

    private func saveNote() {
        guard let db = model.databaseService,
              let audiobookID = model.folderURL?.absoluteString,
              !text.isEmpty else { return }
        let dao = NoteDAO(db: db.writer)
        let record = NoteRecord(
            id: UUID().uuidString,
            audiobookID: audiobookID,
            text: text,
            mediaTimestamp: timestamp,
            realTimestamp: Date().ISO8601Format(),
            isEnabled: true,
            playlistPosition: nil,
            createdAt: Date().ISO8601Format(),
            modifiedAt: Date().ISO8601Format()
        )
        do {
            try dao.insert(record)
        } catch {
            os_log(.error, "Failed to save note: %{public}@", error.localizedDescription)
            saveError = String(localized: "Could not save note: \(error.localizedDescription)")
        }
    }
}
