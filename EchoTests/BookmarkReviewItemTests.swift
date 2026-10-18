// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct BookmarkReviewItemTests {
    @Test func pictureFilterKeepsImageBookmarksSortedByTimestamp() {
        let bookmarks = [
            Bookmark(title: "Later picture", timestamp: 30, bookmarkImageFileName: "later.jpg"),
            Bookmark(title: "No media", timestamp: 10),
            Bookmark(title: "Early picture", timestamp: 20, bookmarkImageFileName: "early.jpg"),
        ]

        let items = BookmarkReviewItem.items(from: bookmarks, filter: .pictures)

        #expect(items.map(\.title) == ["Early picture", "Later picture"])
        #expect(items.map(\.imageFileName) == ["early.jpg", "later.jpg"])
    }

    @Test func voiceMemoFilterKeepsVoiceMemoBookmarks() {
        let bookmarks = [
            Bookmark(title: "Picture", timestamp: 10, bookmarkImageFileName: "photo.jpg"),
            Bookmark(title: "Memo", timestamp: 20, voiceMemoFileName: "memo.m4a"),
        ]

        let items = BookmarkReviewItem.items(from: bookmarks, filter: .voiceMemos)

        #expect(items.map(\.title) == ["Memo"])
        #expect(items.first?.voiceMemoFileName == "memo.m4a")
    }

    @Test func allFilterKeepsEveryBookmarkAndFlagsReviewMedia() {
        let bookmarks = [
            Bookmark(title: "Plain", timestamp: 5),
            Bookmark(title: "Picture", timestamp: 10, bookmarkImageFileName: "photo.jpg"),
            Bookmark(title: "Memo", timestamp: 20, voiceMemoFileName: "memo.m4a"),
        ]

        let items = BookmarkReviewItem.items(from: bookmarks, filter: .all)

        #expect(items.map(\.title) == ["Plain", "Picture", "Memo"])
        #expect(items.map(\.hasReviewMedia) == [false, true, true])
    }
}
