// SPDX-License-Identifier: GPL-3.0-or-later
#if os(macOS)
import AppKit
#else
import UIKit
#endif
import SwiftUI

#if os(macOS)
private typealias LibraryPlatformImage = NSImage
#else
private typealias LibraryPlatformImage = UIImage
#endif

struct LibraryCoverImage: View {
    let coverArtPath: String?
    @State private var image: LibraryPlatformImage?

    var body: some View {
        Group {
            if let image {
                platformImage(image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
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
            image = await loadImage(at: url)
        }
    }

    private func platformImage(_ image: LibraryPlatformImage) -> Image {
        #if os(macOS)
        Image(nsImage: image)
        #else
        Image(uiImage: image)
        #endif
    }

    private func loadImage(at url: URL) async -> LibraryPlatformImage? {
        #if os(macOS)
        await Task.detached {
            NSImage(contentsOf: url)
        }.value
        #else
        await ArtworkCache.loadImageFile(at: url)
        #endif
    }
}
