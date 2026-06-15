import SwiftUI

struct VoicePickerView: View {
    @Bindable var viewModel: BookDetailViewModel
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        NavigationStack {
            List(VoiceCatalog.all) { voice in
                Button {
                    viewModel.selectedVoice = voice
                } label: {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(voice.displayName)
                                .font(.headline)
                            Text(voice.descriptor)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                        
                        if viewModel.selectedVoice.id == voice.id {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.tint)
                                .accessibilityHidden(true)
                        }
                    }
                    .contentShape(Rectangle())
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(viewModel.selectedVoice.id == voice.id ? [.isSelected] : [])
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
                        // Pass empty blocks here for the stub; in a real scenario, we'd pass the actual blocks
                        viewModel.startNarration(blocks: [])
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
