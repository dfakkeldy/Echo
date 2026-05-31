import SwiftUI

enum WatchArtworkLayout: String {
    case immersive
    case classic
}

enum WatchBackgroundStyle: String {
    case artwork
    case black
}

struct WatchControlBackground<S: Shape>: View {
    let shape: S

    var body: some View {
        shape
            .fill(Color.black.opacity(0.52))
            .background(.ultraThinMaterial, in: shape)
            .overlay {
                shape.stroke(Color.white.opacity(0.06), lineWidth: 0.5)
            }
    }
}
