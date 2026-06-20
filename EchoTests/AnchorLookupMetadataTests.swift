// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct AnchorLookupMetadataTests {
    @Test func absRecordUsesRealTitleAuthorNotFolderUUID() {
        let folder = URL(fileURLWithPath: "/x/ABSLibrary/ceda5d9b-uuid")
        let rec = AudiobookRecord(
            id: folder.absoluteString, title: "Hungry Ghosts", author: "Gabor Mate",
            duration: 100, fileCount: 1, addedAt: "t",
            sourceType: "audiobookshelf", serverID: "s", remoteItemID: "r", topicsJSON: nil)
        let (title, author) = EPUBAutoImportScanner.anchorLookupMetadata(
            folderURL: folder, record: rec)
        #expect(title == "Hungry Ghosts")
        #expect(author == "Gabor Mate")
    }
    @Test func nilRecordFallsBackToFolderNames() {
        let folder = URL(fileURLWithPath: "/Users/me/Audiobooks/Some Author/Some Title")
        let (title, author) = EPUBAutoImportScanner.anchorLookupMetadata(
            folderURL: folder, record: nil)
        #expect(title == "Some Title")
        #expect(author == "Some Author")
    }
    @Test func localRecordWithNilAuthorFallsBackToParentFolder() {
        let folder = URL(fileURLWithPath: "/Users/me/Audiobooks/Author Name/Book Title")
        let rec = AudiobookRecord(
            id: folder.absoluteString, title: "Book Title", author: nil,
            duration: 100, fileCount: 1, addedAt: "t")
        let (title, author) = EPUBAutoImportScanner.anchorLookupMetadata(
            folderURL: folder, record: rec)
        #expect(title == "Book Title")
        #expect(author == "Author Name")  // local books keep current behavior (parent folder = author)
    }
}
