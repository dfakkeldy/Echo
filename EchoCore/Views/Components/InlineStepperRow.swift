import SwiftUI

/// A reusable inline stepper with minus/plus buttons, suitable for settings forms.
/// Use this instead of raw `Stepper` when you want compact horizontal layout
/// with monospaced value display and accessibility labels.
struct InlineStepperRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let valueText: String

    var body: some View {
        HStack {
            Text(title)
            Spacer(minLength: 12)
            HStack(spacing: 12) {
                Button {
                    value = max(range.lowerBound, value - step)
                } label: {
                    Image(systemName: "minus.circle.fill")
                }
                .buttonStyle(.plain)
                .disabled(value <= range.lowerBound)

                Text(valueText)
                    .monospacedDigit()
                    .frame(minWidth: 56, alignment: .center)

                Button {
                    value = min(range.upperBound, value + step)
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .buttonStyle(.plain)
                .disabled(value >= range.upperBound)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(title)
            .accessibilityValue(valueText)
            .accessibilityHint(Text("Use minus and plus buttons to adjust"))
        }
    }
}
