// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct ExportMetadataCompletenessTests {
    @Test func incompleteWhenAuthorMissing() {
        #expect(!ExportMetadata(title: "T", author: nil, coverArt: Data([1])).isComplete)
        #expect(!ExportMetadata(title: "T", author: "", coverArt: Data([1])).isComplete)
    }

    @Test func incompleteWhenCoverMissing() {
        #expect(!ExportMetadata(title: "T", author: "A", coverArt: nil).isComplete)
    }

    @Test func completeWithBoth() {
        #expect(ExportMetadata(title: "T", author: "A", coverArt: Data([1])).isComplete)
    }
}
