// SPDX-License-Identifier: GPL-3.0-or-later
#if canImport(UIKit)
    import SwiftUI

    /// A single round Liquid Glass control. iOS 26 gets the real glass effect;
    /// earlier systems get the app's established material-plus-stroke treatment
    /// (deployment floor is iOS 18, so the fallback is mandatory).
    struct GlassControlButton<Label: View>: View {
        var diameter: CGFloat = 56
        let action: () -> Void
        @ViewBuilder let label: () -> Label

        var body: some View {
            Button(action: action) {
                label()
                    .frame(width: diameter, height: diameter)
                    .contentShape(.circle)
            }
            .buttonStyle(.plain)
            .modifier(GlassCircleBackground())
        }
    }

    /// Shared circular glass chrome, also used for Menu-based controls that
    /// cannot be a plain Button (sleep timer, overflow).
    struct GlassCircleBackground: ViewModifier {
        func body(content: Content) -> some View {
            if #available(iOS 26.0, *) {
                content.glassEffect(.regular.interactive(), in: .circle)
            } else {
                content
                    .background(.ultraThinMaterial, in: .circle)
                    .overlay(Circle().stroke(.white.opacity(0.25), lineWidth: 1))
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
            }
        }
    }
#endif
