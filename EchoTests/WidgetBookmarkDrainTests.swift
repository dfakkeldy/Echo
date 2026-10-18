// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// Covers the widget/Siri → app bookmark hand-off. `CreateBookmarkIntent`
/// (in the widget extension) can only stage bookmarks in App Group
/// `UserDefaults` under `bookmarks_<folderKey>`; the app must drain those into
/// the real per-book store on foreground / book load, or they never surface.
@MainActor
struct WidgetBookmarkDrainTests {

    @Test("Widget bookmarks drain into the current book, dedupe by id, and clear the app group")
    func drainsIntoCurrentBookDedupesByIDAndClears() throws {
        let model = PlayerModel()

        // A real temp folder gives the current book a `folderURL`, so
        // `bookmarksStorageKey` resolves and matches the app-group key suffix.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("EchoWidgetDrain-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        model.folderURL = folder
        let storageKey = try #require(model.bookmarksStorageKey)
        let appGroupKey = "bookmarks_\(storageKey)"

        // Isolated stand-in for the shared app group the widget intent wrote to.
        let suiteName = "com.echo.tests.widgetdrain.\(UUID().uuidString)"
        let appGroup = try #require(UserDefaults(suiteName: suiteName))
        appGroup.removePersistentDomain(forName: suiteName)
        defer { appGroup.removePersistentDomain(forName: suiteName) }
        // `saveBookmarks` mirrors to `.standard`; keep the test hermetic.
        defer { UserDefaults.standard.removeObject(forKey: appGroupKey) }

        // One bookmark already lives in the active store.
        let existing = Bookmark(
            id: UUID(), title: "Existing", folderKey: storageKey, trackId: nil, timestamp: 10)
        model.bookmarkStore.bookmarks = [existing]

        // The widget staged a duplicate of `existing` (same id) plus a new one.
        let fresh = Bookmark(
            id: UUID(), title: "From Widget", folderKey: storageKey, trackId: nil, timestamp: 5)
        let staged = try JSONEncoder().encode([existing, fresh])
        appGroup.set(staged, forKey: appGroupKey)

        model.drainPendingWidgetBookmarks(from: appGroup)

        // The live store now holds both, de-duplicated by id and sorted by time.
        let drained = model.bookmarkStore.bookmarks
        #expect(drained.count == 2)
        #expect(Set(drained.map(\.id)) == Set([existing.id, fresh.id]))
        #expect(drained.map(\.timestamp) == [5, 10])

        // The staged entry is cleared so it is never re-imported.
        #expect(appGroup.data(forKey: appGroupKey) == nil)
    }
}
