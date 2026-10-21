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
                if !VoiceCatalog.phonon.isEmpty {
                    Section {
                        Text(
                            "Phonon 31M downloads a 137 MB model on first use. It reads text directly, with paragraph read-along; Kokoro's IPA pronunciation corrections and exact word timings do not apply."
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
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
