import SwiftUI

struct VoicePickerView: View {
    @Binding var selectedVoice: NarrationVoice
    let onStart: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(VoiceCatalog.all) { voice in
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
                        if selectedVoice.id == voice.id {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                                .accessibilityHidden(true)
                        }
                    }
                    .contentShape(Rectangle())
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(selectedVoice.id == voice.id ? [.isSelected] : [])
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Choose a Voice")
            .navigationBarTitleDisplayMode(.inline)
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
        .presentationDetents([.medium])
    }
}
