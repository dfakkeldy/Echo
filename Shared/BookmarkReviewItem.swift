// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum BookmarkReviewFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case pictures
    case voiceMemos

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .pictures: "Pictures"
        case .voiceMemos: "Voice Memos"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "bookmark"
        case .pictures: "photo"
        case .voiceMemos: "waveform"
        }
    }

    func matches(_ item: BookmarkReviewItem) -> Bool {
        switch self {
        case .all:
            true
        case .pictures:
            item.imageFileName != nil
        case .voiceMemos:
            item.voiceMemoFileName != nil
        }
    }
}

struct BookmarkReviewItem: Identifiable, Equatable, Sendable {
    let bookmark: Bookmark

    var id: UUID { bookmark.id }
    var title: String { bookmark.title }
    var timestamp: TimeInterval { bookmark.timestamp }
    var note: String? { bookmark.note }
    var imageFileName: String? { bookmark.bookmarkImageFileName }
    var voiceMemoFileName: String? { bookmark.voiceMemoFileName }
    var hasReviewMedia: Bool { imageFileName != nil || voiceMemoFileName != nil }

    static func items(from bookmarks: [Bookmark], filter: BookmarkReviewFilter) -> [BookmarkReviewItem] {
        bookmarks
            .sorted { $0.timestamp < $1.timestamp }
            .map(BookmarkReviewItem.init(bookmark:))
            .filter(filter.matches)
    }
}
