// SPDX-License-Identifier: GPL-3.0-or-later
#if canImport(UIKit)
    import SwiftUI

    /// Wraps any artwork so tapping opens the fullscreen viewer and long-pressing
    /// saves to Photos with a real add-only permission flow. One component so
    /// cover art and reader images behave identically.
    struct ZoomableArtwork<Label: View>: View {
        let image: UIImage
        let accessibilityLabel: Text
        @ViewBuilder let label: () -> Label

        @State private var showingViewer = false
        @State private var saveOutcome: PhotoLibrarySaver.SaveOutcome?
        private let saver = PhotoLibrarySaver()

        var body: some View {
            Button {
                showingViewer = true
            } label: {
                label()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint("Double tap to view full screen")
            .accessibilityAction(named: "Save to Photos") { saveToPhotos() }
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                    saveToPhotos()
                }
            )
            .fullScreenCover(isPresented: $showingViewer) {
                FullscreenImageViewer(image: image)
            }
            .alert(
                "Photos Access Needed",
                isPresented: Binding(
                    get: { saveOutcome == .denied },
                    set: { if !$0 { saveOutcome = nil } })
            ) {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Allow Echo to add images to your photo library in Settings.")
            }
            .sensoryFeedback(.success, trigger: saveOutcome == .saved)
        }

        private func saveToPhotos() {
            Task {
                saveOutcome = await saver.save(image)
                if saveOutcome == .saved || saveOutcome == .failed {
                    try? await Task.sleep(for: .seconds(2))
                    saveOutcome = nil
                }
            }
        }
    }
#endif
