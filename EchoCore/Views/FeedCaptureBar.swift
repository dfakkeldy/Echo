// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

/// A compact capture overlay for the reader feed: add a note, or record a voice
/// memo. Both anchor to the supplied block. iOS only.
struct FeedCaptureBar: View {
    /// The block the new note/memo will anchor to (typically the active block).
    let anchorBlockID: String?
    let onAddNote: (_ text: String, _ blockID: String) -> Void
    let onStartRecording: () -> Void
    let onStopRecording: (_ blockID: String) -> Void

    @State private var isComposingNote = false
    @State private var noteText = ""
    @State private var isRecording = false

    var body: some View {
        HStack(spacing: 16) {
            Button {
                isComposingNote = true
            } label: {
                Label("Add note", systemImage: "note.text.badge.plus")
            }
            .disabled(anchorBlockID == nil)

            Button {
                if isRecording {
                    if let id = anchorBlockID { onStopRecording(id) }
                    isRecording = false
                } else {
                    onStartRecording()
                    isRecording = true
                }
            } label: {
                Label(
                    isRecording ? "Stop" : "Record memo",
                    systemImage: isRecording ? "stop.circle.fill" : "mic.circle")
            }
            .disabled(anchorBlockID == nil)
            .tint(isRecording ? .red : .accentColor)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .sheet(isPresented: $isComposingNote) {
            NavigationStack {
                TextEditor(text: $noteText)
                    .padding()
                    .navigationTitle("New Note")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") {
                                noteText = ""
                                isComposingNote = false
                            }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") {
                                if let id = anchorBlockID,
                                    !noteText.trimmingCharacters(in: .whitespacesAndNewlines)
                                        .isEmpty
                                {
                                    onAddNote(noteText, id)
                                }
                                noteText = ""
                                isComposingNote = false
                            }
                        }
                    }
            }
        }
    }
}
