// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct VoicePickerView: View {
    @Binding var selectedVoice: NarrationVoice
    let onStart: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(VoiceCatalog.sections) { section in
                    Section(section.title) {
                        ForEach(section.voices) { voice in
                            voiceRow(voice)
                        }
                    }
                }
            }
            .navigationTitle("Choose a Voice")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start Narration") {
                        onStart()
                        dismiss()
                    }
                }
            }
        }
        #if os(iOS)
            .presentationDetents([.medium])
        #endif
    }

    @ViewBuilder
    private func voiceRow(_ voice: NarrationVoice) -> some View {
        let isSelected = selectedVoice.id == voice.id
        Button {
            selectedVoice = voice
        } label: {
            HStack {
                VStack(alignment: .leading) {
                    Text(voice.displayName).font(.headline)
                    Text(voice.descriptor)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        }
        .buttonStyle(.plain)
    }
}
