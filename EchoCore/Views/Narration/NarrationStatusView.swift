import SwiftUI

struct NarrationStatusView: View {
    @Bindable var state: NarrationState
    
    var body: some View {
        Group {
            if state.isRunning {
                HStack(spacing: 12) {
                    if state.phase == .preparingChapter {
                        ProgressView()
                            .controlSize(.small)
                    }
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.statusMessage)
                            .font(.caption)
                            .bold()
                        
                        if state.progress > 0 && state.progress < 1 {
                            ProgressView(value: state.progress)
                        }
                    }
                }
                .padding(8)
                .background(.regularMaterial)
                .clipShape(.rect(cornerRadius: 8))
                .accessibilityElement(children: .combine)
                .transition(.move(edge: .top).combined(with: .opacity))
            } else if state.phase == .failed {
                HStack {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(state.errorMessage ?? "Narration failed")
                        .font(.caption)
                }
                .padding(8)
                .background(.red.opacity(0.1))
                .clipShape(.rect(cornerRadius: 8))
                .accessibilityElement(children: .combine)
            }
        }
        .animation(.default, value: state.phase)
    }
}
