import SwiftUI

struct NarrationNudgeView: View {
    @Bindable var viewModel: BookDetailViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "headphones")
                    .font(.title2)
                    .foregroundStyle(.tint)
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("No audiobook for this one")
                        .font(.headline)
                    Text("Echo can narrate it on-device so you can study hands-free.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            
            Button {
                viewModel.isShowingVoicePicker = true
            } label: {
                Text("Listen \u{25B8}")
                    .bold()
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .clipShape(.rect(cornerRadius: 12))
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(.rect(cornerRadius: 16))
        .sheet(isPresented: $viewModel.isShowingVoicePicker) {
            VoicePickerView(viewModel: viewModel)
        }
    }
}
