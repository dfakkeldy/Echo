import SwiftUI

// MARK: - FidgetOverlayView

/// A sheet-based overlay that provides fidget modes for tactile stimulation
/// during audiobook playback.  Three modes are available:
///
///  1. **Doodle** (iOS only) — PencilKit canvas with color picker
///  2. **Tactile** — Bubble Pop, Kinetic Sand, Infinity Scroll
///  3. **Visualizer** — Placeholder for WS-10
struct FidgetOverlayView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var mode: FidgetMode = .doodle
    let audiobookID: String

    enum FidgetMode: String, CaseIterable {
        case doodle
        case tactile
        case visualizer

        var sfSymbol: String {
            switch self {
            case .doodle:     return "pencil.tip"
            case .tactile:    return "hand.raised.fingers.spread"
            case .visualizer: return "waveform"
            }
        }
    }

    /// Modes available on the current platform.
    private var availableModes: [FidgetMode] {
#if os(iOS)
        FidgetMode.allCases
#else
        [.tactile, .visualizer]
#endif
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Mode", selection: $mode) {
                    ForEach(availableModes, id: \.self) { m in
                        Label(m.rawValue.capitalized, systemImage: m.sfSymbol).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .padding()

                Group {
                    switch mode {
                    case .doodle:
#if os(iOS)
                        DoodlePadView(audiobookID: audiobookID)
#else
                        unavailableView
#endif
                    case .tactile:
                        TactilePlaygroundView()
                    case .visualizer:
                        placeholderView
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .navigationTitle("Fidget")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    // MARK: - Placeholder views

    private var placeholderView: some View {
        VStack(spacing: 12) {
            Image(systemName: "waveform.and.magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("Visualizer")
                .font(.title3).fontWeight(.semibold)
            Text("Coming in a future update — audio-reactive visuals will appear here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }

    private var unavailableView: some View {
        VStack(spacing: 12) {
            Image(systemName: "pencil.slash")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)
            Text("Doodle Pad")
                .font(.title3).fontWeight(.semibold)
            Text("Doodle mode requires a touchscreen device.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
    }
}
