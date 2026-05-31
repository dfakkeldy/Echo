import SwiftUI

struct ToggleTraitModifier: ViewModifier {
    let isToggle: Bool
    let value: String?

    func body(content: Content) -> some View {
        if isToggle {
            content
                .accessibilityAddTraits(.isToggle)
                .accessibilityValue(value ?? "")
        } else {
            content
        }
    }
}
