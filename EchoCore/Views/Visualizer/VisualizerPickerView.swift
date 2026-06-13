import SwiftUI

// MARK: - VisualizerPickerView

/// A full-screen audio visualizer with a segmented picker at the bottom to
/// switch between the four Metal shader styles.
///
/// The view consumes an `AsyncStream<VisualizerFrame>` — typically obtained
/// from `AudioEngine.visualizerTap.frames` — to drive real-time audio-reactive
/// visuals.
struct VisualizerPickerView: View {
    @State private var style: VisualizerStyle = .acidWarp
    let frameStream: AsyncStream<VisualizerFrame>

    var body: some View {
        ZStack(alignment: .bottom) {
            VisualizerView(style: style, frameStream: frameStream)
                .ignoresSafeArea()

            Picker("Style", selection: $style) {
                ForEach(VisualizerStyle.allCases, id: \.self) { s in
                    Label(s.rawValue, systemImage: s.sfSymbol).tag(s)
                }
            }
            .pickerStyle(.segmented)
            .padding()
            .background(.ultraThinMaterial)
        }
    }
}
