// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// Loads a local image file for a study card. Shared by assignment cards and
/// the general review cards. Shows a placeholder when the path is nil/missing.
struct StudyLocalImageView: View {
    let path: String?
    let accessibilityLabel: String

    var body: some View {
        #if canImport(UIKit)
            if let path, let image = UIImage(contentsOfFile: path) {
                StudyDecoratedImageView(
                    image: Image(uiImage: image), accessibilityLabel: accessibilityLabel)
            } else {
                StudyUnavailableImagePlaceholder()
            }
        #elseif canImport(AppKit)
            if let path, let image = NSImage(contentsOfFile: path) {
                StudyDecoratedImageView(
                    image: Image(nsImage: image), accessibilityLabel: accessibilityLabel)
            } else {
                StudyUnavailableImagePlaceholder()
            }
        #else
            StudyUnavailableImagePlaceholder()
        #endif
    }
}

struct StudyDecoratedImageView: View {
    let image: Image
    let accessibilityLabel: String

    var body: some View {
        image
            .resizable()
            .scaledToFit()
            .clipShape(.rect(cornerRadius: 8))
            .accessibilityLabel(Text(accessibilityLabel))
    }
}

struct StudyUnavailableImagePlaceholder: View {
    var body: some View {
        Image(systemName: "photo")
            .font(.largeTitle)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 160)
            .background(.secondary.opacity(0.08))
            .clipShape(.rect(cornerRadius: 8))
            .accessibilityLabel(Text("Image unavailable"))
    }
}
