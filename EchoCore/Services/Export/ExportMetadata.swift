// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation

/// Book-level tags embedded in the exported file. Cover art is raw image data
/// (JPEG/PNG bytes) so the type stays cross-platform (no UIImage/NSImage).
struct ExportMetadata: Equatable {
    var title: String
    var author: String?
    var coverArt: Data?

    /// AVFoundation common-key metadata items for the export pass.
    func assetMetadataItems() -> [AVMetadataItem] {
        var items: [AVMetadataItem] = []
        items.append(Self.item(.commonIdentifierTitle, value: title as NSString))
        if let author, !author.isEmpty {
            items.append(Self.item(.commonIdentifierArtist, value: author as NSString))
        }
        if let coverArt {
            items.append(Self.item(.commonIdentifierArtwork, value: coverArt as NSData))
        }
        return items
    }

    private static func item(_ id: AVMetadataIdentifier, value: NSCopying & NSObjectProtocol)
        -> AVMetadataItem
    {
        let item = AVMutableMetadataItem()
        item.identifier = id
        item.value = value
        item.extendedLanguageTag = "und"
        return item
    }
}
