// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
@Suite struct LibraryPermanentAccessTests {
    @Test func scannerSplitsFlatM4BFolderIntoIndividualBooksWithStemCompanions() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("flat-m4b-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        let war = root.appendingPathComponent("The War of Art.m4b")
        let deep = root.appendingPathComponent("Deep Work.m4b")
        let year = root.appendingPathComponent("1984.m4b")
        let warEpub = root.appendingPathComponent("The War of Art.epub")
        try Data().write(to: war)
        try Data().write(to: deep)
        try Data().write(to: year)
        try Data().write(to: warEpub)

        let books = LibraryScanner.discoverBooks(in: root)
        #expect(books.count == 3)
        #expect(
            Set(books.map { LibraryScanner.fallbackTitle(for: $0) })
                == ["The War of Art", "Deep Work", "1984"])

        let warBook = try #require(books.first { $0.folderURL.lastPathComponent == "The War of Art.m4b" })
        let deepBook = try #require(books.first { $0.folderURL.lastPathComponent == "Deep Work.m4b" })
        #expect(warBook.companionEPUB?.lastPathComponent == "The War of Art.epub")
        #expect(deepBook.companionEPUB == nil)
    }

    @Test func scannerKeepsMultiPartM4BSetGroupedInOneFolder() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("multipart-m4b-\(UUID().uuidString)", isDirectory: true)
        let duneDir = root.appendingPathComponent("Dune", isDirectory: true)
        let numericDir = root.appendingPathComponent("Numeric", isDirectory: true)
        try fm.createDirectory(at: duneDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: numericDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        try Data().write(to: duneDir.appendingPathComponent("Dune Part 1.m4b"))
        try Data().write(to: duneDir.appendingPathComponent("Dune Part 2.m4b"))
        try Data().write(to: numericDir.appendingPathComponent("01 - Intro.m4b"))
        try Data().write(to: numericDir.appendingPathComponent("02 - Chapter 1.m4b"))

        let books = LibraryScanner.discoverBooks(in: root)
        #expect(books.count == 2)
        #expect(Set(books.map { $0.folderURL.lastPathComponent }) == ["Dune", "Numeric"])
        for book in books {
            #expect(book.audioFiles.count == 2)
        }
    }

    @Test func relativePathResolvesAcrossDriftedRootPrefix() throws {
        let oldRoot = URL(fileURLWithPath: "/Containers/OldUUID/OpenAudible", isDirectory: true)
        let newRoot = URL(fileURLWithPath: "/Containers/NewUUID/OpenAudible", isDirectory: true)
        let oldBook = oldRoot.appendingPathComponent("The War of Art.m4b")

        let rel = try #require(LibraryAccess.relativePath(of: oldBook, from: oldRoot))
        #expect(rel == "The War of Art.m4b")

        let resolved = try #require(
            LibraryAccess.resolveChildURL(
                resolvedRoot: newRoot,
                relativePath: rel,
                fallbackURL: oldBook,
                rootDisplayName: "OpenAudible"))
        #expect(resolved.path == "/Containers/NewUUID/OpenAudible/The War of Art.m4b")

        // Legacy row without source_relative_path still rebases via rootDisplayName.
        let legacyResolved = try #require(
            LibraryAccess.resolveChildURL(
                resolvedRoot: newRoot,
                relativePath: nil,
                fallbackURL: oldBook,
                rootDisplayName: "OpenAudible"))
        #expect(legacyResolved.path == "/Containers/NewUUID/OpenAudible/The War of Art.m4b")
    }

    @Test func rescanPersistsSourceRelativePathAndUrlForOpeningUsesLiveRoot() throws {
        let db = try DatabaseService(inMemory: ())
        let service = LibraryService(db: db)

        let rootDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rel-root-\(UUID().uuidString)", isDirectory: true)
        let bookFile = rootDir.appendingPathComponent("The War of Art.m4b")
        try FileManager.default.createDirectory(at: rootDir, withIntermediateDirectories: true)
        try Data().write(to: bookFile)
        defer { try? FileManager.default.removeItem(at: rootDir) }

        let root = try service.registerRoot(url: rootDir)
        _ = try service.rescan(
            root: root,
            discover: { _ in
                [DiscoveredBook(folderURL: bookFile, audioFiles: [bookFile], companionEPUB: nil)]
            })

        let saved = try #require(try AudiobookDAO(db: db.writer).get(bookFile.absoluteString))
        #expect(saved.sourceRootID == root.id)
        #expect(saved.sourceRelativePath == "The War of Art.m4b")
        #expect(saved.title == "The War of Art")

        // Simulate a drifted stored ID while sourceRelativePath stays valid.
        var drifted = saved
        drifted.id = "file:///StaleMount/OpenAudible/The%20War%20of%20Art.m4b"
        let target = try service.urlForOpening(drifted)
        #expect(
            target.url.standardizedFileURL.resolvingSymlinksInPath()
                == bookFile.standardizedFileURL.resolvingSymlinksInPath())
    }

    @Test func dispatcherRoutesStandaloneM4BFileAsAudio() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("single-\(UUID().uuidString).m4b")
        try Data("audio".utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let route = try LibraryBookOpenDispatcher().route(
            for: LibraryOpenTarget(url: tmp, scopedRoot: nil))
        #expect(route == .audioFile(tmp))
    }

    /// A flat-root M4B must reach the single-file consumer, never the folder
    /// loader, which lists directory contents and silently fails on a file.
    @Test func dispatcherOpensStandaloneM4BThroughAudioFileConsumer() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("flat-root-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let book = root.appendingPathComponent("Dune.m4b")
        try Data("audio".utf8).write(to: book)
        var events: [String] = []

        try LibraryBookOpenDispatcher().open(
            LibraryOpenTarget(url: book, scopedRoot: root),
            retainSecurityScope: { events.append("retain:\($0.lastPathComponent)") },
            releaseSecurityScope: { events.append("release") },
            openAudioFolder: { events.append("folder:\($0.lastPathComponent)") },
            openAudioFile: { events.append("file:\($0.lastPathComponent)") },
            openAudiolessDocument: { _, _ in events.append("document") })

        #expect(events == ["retain:\(root.lastPathComponent)", "file:Dune.m4b"])
    }

    @Test func libraryViewModelTracksPermissionRecoveryOnPermissionDenied() throws {
        let db = try DatabaseService(inMemory: ())
        let book = AudiobookRecord(
            id: "file:///Books/Locked.m4b",
            title: "Locked",
            author: nil,
            duration: 0,
            fileCount: 1,
            addedAt: "2026-11-27T00:00:00Z",
            isAvailable: true)

        let vm = LibraryViewModel(db: db, listenedOnly: false) { target in
            throw LibraryBookOpenError.permissionDenied(target.url)
        }
        vm.open(book)

        #expect(vm.permissionRecoveryBook?.id == book.id)
        #expect(vm.errorMessage == LibraryBookOpenError.permissionDenied(URL(string: book.id)!).localizedDescription)
    }

    @Test func playbackErrorNoticeClassifiesPermissionAndUnavailableFailures() {
        let perm = PlaybackErrorNotice.fromLoadFailure(
            "NSError: The file couldn't be opened because you don't have permission to view it (Code=257)")
        #expect(perm == .permissionDenied)
        #expect(perm.allowsReopenPicker)

        let missing = PlaybackErrorNotice.fromLoadFailure(
            "NSError: The file doesn't exist (Code=260)")
        #expect(missing == .fileUnavailable)
        #expect(missing.allowsReopenPicker)
    }

    @Test func playbackControllerPublishesAndClearsPlaybackError() {
        let controller = PlaybackController()
        controller.reportTrackLoadFailure(
            AudioItemLoadFailure(privateDetail: "Operation not permitted (EPERM)"))
        #expect(controller.state.playbackError == .permissionDenied)

        controller.reportTrackLoading()
        #expect(controller.state.playbackError == nil)

        controller.state.tracks = [
            Track(url: URL(fileURLWithPath: "/missing/book.m4b"), title: "Missing")
        ]
        controller.coordinator_configureAudioSession = {}
        controller.coordinator_loadTrack = { _, _ in }
        controller.coordinator_startSecurityScope = {}
        controller.play()
        #expect(controller.state.playbackError == .fileUnavailable)
    }
}
