// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
@Suite struct LibraryBookmarkAccessTests {
    @Test func perBookBookmarkRoundTripsAndRefreshesWhenStale() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("per-book-bookmark-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let fileURL = tmp.appendingPathComponent("The War of Art.m4b")
        try Data("audio".utf8).write(to: fileURL)

        var store: [String: Data] = [:]
        let saved = LibraryAccess.saveBookBookmark(
            for: fileURL,
            bookID: fileURL.absoluteString,
            saveData: { data, account in
                store[account] = data
                return true
            })
        #expect(saved)

        var refreshCount = 0
        let resolved = LibraryAccess.resolveBookBookmark(
            for: fileURL.absoluteString,
            loadData: { store[$0] },
            resolveData: { data in
                guard let base = LibraryAccess.resolveURL(from: data) else { return nil }
                return (base.url, true)  // simulate iOS stale bookmark
            },
            saveData: { data, account in
                refreshCount += 1
                store[account] = data
                return true
            })
        #expect(resolved?.standardizedFileURL == fileURL.standardizedFileURL)
        #expect(refreshCount == 1)
    }

    @Test func urlForOpeningResolvesPerBookBookmarkForStandaloneBook() throws {
        let db = try DatabaseService(inMemory: ())
        let service = LibraryService(db: db)

        let storedURL = URL(fileURLWithPath: "/Books/The War of Art.m4b")
        let scopedURL = URL(fileURLWithPath: "/private/Books/The War of Art.m4b")
        let book = AudiobookRecord(
            id: storedURL.absoluteString,
            title: "The War of Art",
            author: "Steven Pressfield",
            duration: 3600,
            fileCount: 1,
            addedAt: "2026-11-27T00:00:00Z",
            isAvailable: true,
            sourceRootID: nil)

        let target = try service.urlForOpening(
            book,
            resolveBookBookmark: { id in
                id == book.id ? scopedURL : nil
            },
            restoreLastSelectionBookmark: { nil },
            isReadableWithoutScope: { _ in false })

        #expect(target.url == scopedURL)
        #expect(target.scopedRoot == nil)
    }

    @Test func urlForOpeningFallsBackToCoveringLibraryRootWhenUnreadableWithoutScope() throws {
        let db = try DatabaseService(inMemory: ())
        let service = LibraryService(db: db)

        let parent = FileManager.default.temporaryDirectory
            .appendingPathComponent("covering-root-\(UUID().uuidString)", isDirectory: true)
        let rootDir = parent.appendingPathComponent("OpenAudible", isDirectory: true)
        let siblingDir = parent.appendingPathComponent("OpenAudible2", isDirectory: true)
        let nestedDir = rootDir.appendingPathComponent("Pressfield", isDirectory: true)
        try FileManager.default.createDirectory(at: nestedDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: siblingDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: parent) }

        let bookURL = nestedDir.appendingPathComponent("The War of Art.m4b")
        try Data("audio".utf8).write(to: bookURL)
        let siblingBookURL = siblingDir.appendingPathComponent("Other.m4b")
        try Data("audio".utf8).write(to: siblingBookURL)

        _ = try service.registerRoot(url: rootDir)
        _ = try service.registerRoot(url: nestedDir)

        let book = AudiobookRecord(
            id: bookURL.absoluteString,
            title: "The War of Art",
            author: nil,
            duration: 3600,
            fileCount: 1,
            addedAt: "2026-11-27T00:00:00Z",
            isAvailable: true,
            sourceRootID: nil)

        let target = try service.urlForOpening(
            book,
            resolveBookBookmark: { _ in nil },
            restoreLastSelectionBookmark: { nil },
            isReadableWithoutScope: { _ in false })

        #expect(target.url.standardizedFileURL == bookURL.standardizedFileURL)
        #expect(
            target.scopedRoot?.standardizedFileURL.resolvingSymlinksInPath()
                == nestedDir.standardizedFileURL.resolvingSymlinksInPath())

        // Sibling path sharing only a string prefix must not match the root.
        let siblingBook = AudiobookRecord(
            id: siblingBookURL.absoluteString,
            title: "Other",
            author: nil,
            duration: 3600,
            fileCount: 1,
            addedAt: "2026-11-27T00:00:00Z",
            isAvailable: true,
            sourceRootID: nil)

        let siblingTarget = try service.urlForOpening(
            siblingBook,
            resolveBookBookmark: { _ in nil },
            restoreLastSelectionBookmark: { nil },
            isReadableWithoutScope: { _ in false })

        #expect(siblingTarget.scopedRoot == nil)
    }

    @Test func openLibraryBookOrThrowRejectsUnreadableUnscopedBookBeforeSwitchingTabs() {
        let model = PlayerModel()
        model.selectedTab = .library
        let unreadableURL = URL(fileURLWithPath: "/nonexistent/Unscoped Book.m4b")
        let target = LibraryOpenTarget(url: unreadableURL, scopedRoot: nil)

        #expect(throws: LibraryBookOpenError.permissionDenied(unreadableURL)) {
            try model.openLibraryBookOrThrow(
                target,
                isReadable: { _ in false },
                isUbiquitous: { _ in false })
        }
        #expect(model.selectedTab == .library)
    }
}
