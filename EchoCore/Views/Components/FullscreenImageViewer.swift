// SPDX-License-Identifier: GPL-3.0-or-later
#if canImport(UIKit)
    import SwiftUI

    /// Edge-to-edge image viewer: pinch to zoom (1×–4×), drag to pan when
    /// zoomed, double-tap to toggle zoom, swipe down or tap Close to dismiss.
    struct FullscreenImageViewer: View {
        let image: UIImage
        @Environment(\.dismiss) private var dismiss

        @State private var zoom: CGFloat = 1
        @State private var steadyZoom: CGFloat = 1
        @State private var pan: CGSize = .zero
        @State private var steadyPan: CGSize = .zero

        var body: some View {
            ZStack(alignment: .topTrailing) {
                Color.black.ignoresSafeArea()

                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .scaleEffect(zoom)
                    .offset(pan)
                    .gesture(zoomAndPanGesture)
                    .onTapGesture(count: 2) {
                        withAnimation(.snappy) {
                            steadyZoom = steadyZoom > 1 ? 1 : 2.5
                            zoom = steadyZoom
                            steadyPan = .zero
                            pan = .zero
                        }
                    }
                    .accessibilityLabel(Text("Full screen image"))
                    .accessibilityAddTraits(.isImage)

                Button("Close", systemImage: "xmark.circle.fill") { dismiss() }
                    .labelStyle(.iconOnly)
                    .font(.title)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding()
            }
            .gesture(
                // Swipe down while un-zoomed dismisses.
                DragGesture().onEnded { value in
                    if steadyZoom <= 1 && value.translation.height > 80 { dismiss() }
                }
            )
            .statusBarHidden()
        }

        private var zoomAndPanGesture: some Gesture {
            SimultaneousGesture(
                MagnifyGesture()
                    .onChanged { value in
                        zoom = min(max(steadyZoom * value.magnification, 1), 4)
                    }
                    .onEnded { _ in
                        steadyZoom = zoom
                        if zoom <= 1 {
                            withAnimation(.snappy) {
                                pan = .zero
                                steadyPan = .zero
                            }
                        }
                    },
                DragGesture()
                    .onChanged { value in
                        guard steadyZoom > 1 else { return }
                        pan = CGSize(
                            width: steadyPan.width + value.translation.width,
                            height: steadyPan.height + value.translation.height)
                    }
                    .onEnded { _ in steadyPan = pan }
            )
        }
    }

    /// Image presented edge-to-edge by RootTabView's fullScreenCover.
    struct FullscreenImageItem: Identifiable {
        let id = UUID()
        let image: UIImage
    }
#endif
