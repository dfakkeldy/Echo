import Foundation
@testable import Orbit_Audiobooks

/// In-memory BookmarkStore for unit testing.
final class MockBookmarkStore: BookmarkStoreProtocol {
    var bookmarks: [Bookmark] = []
    var bookmarkToAdd: Bookmark?
    var deletedBookmarkIDs: [UUID] = []
    var updatedBookmarks: [(UUID, String, TimeInterval, String?, String?, String?)] = []

    func addBookmark(at time: TimeInterval, trackId: String?, folderKey: String?) -> Bookmark {
        let bookmark = Bookmark(folderKey: folderKey, trackId: trackId, timestamp: time)
        bookmarks.append(bookmark)
        bookmarkToAdd = bookmark
        return bookmark
    }

    func deleteBookmark(id: UUID, folderURL: URL? = nil) {
        deletedBookmarkIDs.append(id)
        bookmarks.removeAll { $0.id == id }
    }

    func updateBookmark(id: UUID, title: String, timestamp: TimeInterval, note: String?,
                        voiceMemoFileName: String?, bookmarkImageFileName: String? = nil) {
        updatedBookmarks.append((id, title, timestamp, note, voiceMemoFileName, bookmarkImageFileName))
        if let index = bookmarks.firstIndex(where: { $0.id == id }) {
            let bm = bookmarks[index]
            bookmarks[index] = Bookmark(
                id: bm.id,
                title: title,
                folderKey: bm.folderKey,
                trackId: bm.trackId,
                timestamp: timestamp,
                note: note,
                voiceMemoFileName: voiceMemoFileName,
                bookmarkImageFileName: bookmarkImageFileName,
                isEnabled: bm.isEnabled
            )
        }
    }
}
