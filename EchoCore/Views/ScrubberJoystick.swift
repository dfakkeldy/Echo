import SwiftUI

struct ScrubberJoystick: View {
    @Binding var value: Double  // -1.0 to 1.0
    var onRelease: () -> Void

    @State private var dragOffset: CGFloat = 0
    private let trackWidth: CGFloat = 200
    private let knobSize: CGFloat = 44

    var body: some View {
        ZStack {
            Capsule()
                .fill(.ultraThinMaterial)
                .frame(width: trackWidth, height: 12)

            Circle()
                .fill(Color.accentColor)
                .frame(width: knobSize, height: knobSize)
                .shadow(radius: 4)
                .offset(x: dragOffset)
                .gesture(
                    DragGesture()
                        .onChanged { gesture in
                            let maxTranslation = (trackWidth - knobSize) / 2
                            let translation = min(
                                max(gesture.translation.width, -maxTranslation), maxTranslation)
                            dragOffset = translation
                            value = Double(translation / maxTranslation)

                            // Exponential mapping so small pulls are slow, big pulls are fast.
                            let sign = value < 0 ? -1.0 : 1.0
                            value = sign * pow(abs(value), 2.0)
                        }
                        .onEnded { _ in
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
                                dragOffset = 0
                                value = 0
                            }
                            onRelease()
                        }
                )
        }
        .frame(height: knobSize)
        // VoiceOver: a continuous drag-scrubber is best exposed as a single
        // direct-interaction element so the gesture passes through, with a
        // spoken label/value/hint (§8.4).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Scrubber")
        .accessibilityValue(
            value == 0
                ? "Centered"
                : "\(value > 0 ? "Forward" : "Backward") \(Int(abs(value) * 100)) percent"
        )
        .accessibilityHint("Drag left or right to scrub; release to stop")
        .accessibilityAddTraits(.allowsDirectInteraction)
    }
}
