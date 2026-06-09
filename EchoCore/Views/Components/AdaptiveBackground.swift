import SwiftUI

struct AdaptiveBackground: View {
    @Environment(PlayerModel.self) private var model

    var body: some View {
        let background = model.artworkPalette.background
        let colors: [Color] = background.isEmpty
            ? [Color.blue.opacity(0.2), Color.purple.opacity(0.2), Color.indigo.opacity(0.2)]
            : background

        ZStack {
            Color(uiColor: .systemBackground)

            LinearGradient(
                colors: [colors[0], colors[1]],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            GeometryReader { geo in
                RadialGradient(
                    colors: [colors.count > 2 ? colors[2] : colors[1], .clear],
                    center: .bottomLeading,
                    startRadius: 0,
                    endRadius: max(geo.size.width, geo.size.height) * 0.85
                )
            }
        }
        .blur(radius: 50)
        .overlay(.ultraThinMaterial)
        .ignoresSafeArea()
    }
}
