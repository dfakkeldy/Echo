// SPDX-License-Identifier: GPL-3.0-or-later
#if canImport(UIKit)
    import SwiftUI

    /// Wraps any artwork so tapping opens the fullscreen viewer and (when a
    /// handler is provided — Task 5) long-pressing triggers save-to-Photos.
    /// One component so cover art and reader images behave identically.
    struct ZoomableArtwork<Label: View>: View {
        let image: UIImage
        let accessibilityLabel: Text
        var onLongPress: (() -> Void)? = nil
        @ViewBuilder let label: () -> Label

        @State private var showingViewer = false

        var body: some View {
            Button {
                showingViewer = true
            } label: {
                label()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint("Double tap to view full screen")
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                    onLongPress?()
                }
            )
            .fullScreenCover(isPresented: $showingViewer) {
                FullscreenImageViewer(image: image)
            }
        }
    }
#endif
