import SwiftUI

/// Full-screen tonal ramp from the current cover's theme: a pale wash in
/// light mode, an immersive deep room in dark mode. Replaces the old
/// three-hue gradient + material stack (spec §5) — one designed hue with
/// tonal depth instead of a pastel soup.
struct AdaptiveBackground: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        let theme = model.coverTheme
        LinearGradient(
            colors: [theme.backgroundTop, theme.backgroundBottom],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }
}
