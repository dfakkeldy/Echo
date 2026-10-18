// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct ScrubberJoystick: View {
    @Binding var value: Double  // -1.0 to 1.0
    var onRelease: () -> Void

    @State private var dragOffset: CGFloat = 0
    private let trackWidth: CGFloat = 200
    private let knobSize: CGFloat = 44
    private let accessibilityStep = 0.25

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
                            updateScrubValue(fromTranslation: gesture.translation.width)
                        }
                        .onEnded { _ in
                            stopScrubbing()
                        }
                )
        }
        .frame(height: knobSize)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Scrubber")
        .accessibilityValue(
            value == 0
                ? "Centered"
                : "\(value > 0 ? "Forward" : "Backward") \(Int(abs(value) * 100)) percent"
        )
        .accessibilityHint("Swipe up or down to scrub, or use actions for forward, backward, and stop")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                adjustScrubbing(by: accessibilityStep)
            case .decrement:
                adjustScrubbing(by: -accessibilityStep)
            @unknown default:
                break
            }
        }
        .accessibilityAction(named: Text("Scrub forward")) {
            adjustScrubbing(by: accessibilityStep)
        }
        .accessibilityAction(named: Text("Scrub backward")) {
            adjustScrubbing(by: -accessibilityStep)
        }
        .accessibilityAction(named: Text("Stop scrubbing")) {
            stopScrubbing()
        }
        .accessibilityAddTraits(.allowsDirectInteraction)
    }

    private var maximumTranslation: CGFloat {
        (trackWidth - knobSize) / 2
    }

    private func updateScrubValue(fromTranslation rawTranslation: CGFloat) {
        let translation = min(max(rawTranslation, -maximumTranslation), maximumTranslation)
        dragOffset = translation

        let linearValue = Double(translation / maximumTranslation)
        let sign = linearValue < 0 ? -1.0 : 1.0
        value = sign * pow(abs(linearValue), 2.0)
    }

    private func adjustScrubbing(by delta: Double) {
        setScrubValue(value + delta)
    }

    private func setScrubValue(_ newValue: Double) {
        let clampedValue = min(max(newValue, -1.0), 1.0)
        value = clampedValue

        let sign = clampedValue < 0 ? -1.0 : 1.0
        let linearValue = sign * sqrt(abs(clampedValue))
        dragOffset = CGFloat(linearValue) * maximumTranslation
    }

    private func stopScrubbing() {
        withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) {
            dragOffset = 0
            value = 0
        }
        onRelease()
    }
}
