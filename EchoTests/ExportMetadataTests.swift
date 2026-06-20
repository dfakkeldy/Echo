// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation
import Testing

@testable import Echo

@Suite struct ExportMetadataTests {
    @Test func buildsTitleAndArtistItems() {
        let meta = ExportMetadata(title: "My Book", author: "Jane Doe", coverArt: nil)
        let items = meta.assetMetadataItems()
        #expect(
            items.contains {
                $0.identifier == .commonIdentifierTitle && ($0.value as? String) == "My Book"
            })
        #expect(
            items.contains {
                $0.identifier == .commonIdentifierArtist && ($0.value as? String) == "Jane Doe"
            })
    }

    @Test func omitsEmptyAuthorAndNilCover() {
        let meta = ExportMetadata(title: "T", author: "", coverArt: nil)
        let items = meta.assetMetadataItems()
        #expect(!items.contains { $0.identifier == .commonIdentifierArtist })
        #expect(!items.contains { $0.identifier == .commonIdentifierArtwork })
    }

    @Test func includesArtworkWhenPresent() {
        let meta = ExportMetadata(title: "T", author: nil, coverArt: Data([0xFF, 0xD8, 0xFF]))
        #expect(meta.assetMetadataItems().contains { $0.identifier == .commonIdentifierArtwork })
    }
}
