import SwiftUI

/// Extracted scrubber HStack that only observes `PlayerModel` via `@Bindable`,
/// isolating the 0.5-second observation updates from the main `ContentView`.
struct PlayerScrubberView: View {
    @Bindable var model: PlayerModel

    @State private var scrubFraction: Double = 0.0
    @State private var isScrubbing = false

    var body: some View {
        HStack(spacing: 12) {
            Text(model.elapsedText)
                .customFont(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Slider(
                value: $scrubFraction,
                in: 0...1,
                onEditingChanged: { editing in
                    isScrubbing = editing
                    if !editing {
                        model.seek(toFraction: scrubFraction)
                    }
                }
            )
            .frame(maxWidth: .infinity)
            .tint(.primary)
            .onChange(of: model.progressFraction) { _, newValue in
                if !isScrubbing {
                    scrubFraction = newValue
                }
            }

            Text(model.progressText)
                .customFont(.footnote)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}