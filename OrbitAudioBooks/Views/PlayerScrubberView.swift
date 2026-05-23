import SwiftUI

/// Extracted scrubber control that only observes `PlayerModel` via `@Bindable`,
/// isolating the 0.5-second observation updates from the main `ContentView`.
struct PlayerScrubberView: View {
    @Environment(PlayerModel.self) private var model

    @State private var scrubFraction: Double = 0.0
    @State private var isScrubbing = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            horizontalScrubber
            verticalScrubber
        }
    }

    private var horizontalScrubber: some View {
        HStack(spacing: 10) {
            timeLabel(model.elapsedText, alignment: .leading)

            scrubber

            timeLabel(model.progressText, alignment: .trailing)
        }
    }

    private var verticalScrubber: some View {
        VStack(spacing: 8) {
            scrubber

            HStack {
                timeLabel(model.elapsedText, alignment: .leading)

                Spacer(minLength: 12)

                timeLabel(model.progressText, alignment: .trailing)
            }
        }
    }

    private var scrubber: some View {
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
        .frame(minWidth: Self.minimumScrubberWidth, maxWidth: .infinity)
        .tint(.primary)
        .accessibilityLabel(Text("Playback position"))
        .accessibilityValue(Text("\(model.elapsedText), \(model.progressText)"))
        .onChange(of: model.progressFraction) { _, newValue in
            if !isScrubbing {
                scrubFraction = newValue
            }
        }
        .onAppear {
            scrubFraction = model.progressFraction
        }
    }

    private func timeLabel(_ text: String, alignment: Alignment) -> some View {
        Text(text)
            .customFont(.footnote, appFont: model.resolvedAppFont)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(width: Self.timeLabelWidth, alignment: alignment)
    }

    private static let timeLabelWidth: CGFloat = 54
    private static let minimumScrubberWidth: CGFloat = 210
}
