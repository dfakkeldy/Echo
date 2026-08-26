// SPDX-License-Identifier: GPL-3.0-or-later
import CoreGraphics
import SwiftUI

struct LibraryCoverImage: View {
    let coverArtPath: String?
    /// Held as a `CGImage` rather than a `UIImage`/`NSImage` because both
    /// platforms can render one through `Image(decorative:scale:)`. That is
    /// what lets the load below be a single shared call: the macOS branch used
    /// to build a full-size `NSImage(contentsOf:)` on every appearance, with no
    /// downsampling and no memo, so scrolling a shelf re-read and re-decoded the
    /// same files. See `CoverImageCache`.
    @State private var image: CGImage?

    var body: some View {
        Group {
            if let image {
                ZStack {
                    // Decorative full-bleed background: a blurred, scrimmed copy of
                    // the cover fills the square cell so a portrait/landscape cover
                    // looks intentional. `.fill` is correct here — this layer is
                    // purely decorative, never the readable cover.
                    coverImage(image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .blur(radius: 12)
                        .overlay(Color.black.opacity(0.12))
                    // The readable cover: aspect-fit, never stretched or cropped, so
                    // title/author art at the cover edges is always visible.
                    coverImage(image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            } else {
                ZStack {
                    Rectangle()
                        .fill(.secondary.opacity(0.12))
                    Image(systemName: "book.closed.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .clipShape(.rect(cornerRadius: 8))
        .task(id: coverArtPath) {
            guard let coverArtPath else {
                image = nil
                return
            }
            let url = FileLocations.libraryCoversDirectory.appending(path: coverArtPath)
            image = await CoverImageCache.image(at: url)
        }
    }

    /// `decorative` matches the previous `Image(uiImage:)`/`Image(nsImage:)`
    /// behaviour: the cover carries no label of its own, because the callers
    /// own the accessibility text (`LibraryCoverCell` combines its children
    /// under a title/author label; the Mac row hides the cover outright).
    private func coverImage(_ image: CGImage) -> Image {
        Image(decorative: image, scale: 1)
    }
}
