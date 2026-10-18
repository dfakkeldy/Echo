// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
struct AuxiliaryNarrationArtifactTests {
    @Test func folderPlaylistExcludesReelsAndKeepsMultipleVolumes() throws {
        let folder = try makeFolder(files: [
            "volume-1.m4b", "volume-2.m4b", "book.pronunciation-reel.m4b",
            "PRONUNCIATION-PROBE-REEL.M4B", "book.epub",
        ])
        defer { try? FileManager.default.removeItem(at: folder) }

        let tracks = makeManager().loadTracks(from: folder)
        #expect(tracks.map(\.url.lastPathComponent) == ["volume-1.m4b", "volume-2.m4b"])
    }

    @Test func explicitlySelectedReelRemainsPlayable() throws {
        let folder = try makeFolder(files: ["book.pronunciation-reel.m4b"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let reel = folder.appending(path: "book.pronunciation-reel.m4b")

        let selection = PlaylistSelectionResolver.resolve(url: reel) { folder in
            makeManager().loadTracks(from: folder)
        }
        #expect(selection.tracks.map(\.url) == [reel])
    }

    @Test(arguments: [false, true])
    func contaminatedManifestPreservesBookState(resumeWasOnReel: Bool) throws {
        let folder = try makeFolder(files: [
            "volume-1.m4b", "volume-2.m4b", "book.pronunciation-reel.m4b",
        ])
        defer { try? FileManager.default.removeItem(at: folder) }
        let firstID = folder.appending(path: "volume-2.m4b").absoluteString
        let manifest = EchoPlaylistManifest(
            title: "Book", author: "Author",
            tracks: [
                .init(file: "volume-2.m4b", title: "Second volume", duration: 200, enabled: false),
                .init(file: "book.pronunciation-reel.m4b", title: "Review", duration: 5),
                .init(file: "volume-1.m4b", title: "First volume", duration: 100),
            ],
            playbackState: .init(
                lastTrackId: resumeWasOnReel
                    ? folder.appending(path: "book.pronunciation-reel.m4b").absoluteString
                    : firstID,
                lastPosition: 42, speed: 1.5, loopMode: "all"),
            bookmarks: [.init(id: "bookmark", title: "Note", timestamp: 12, note: "Keep this")]
        )
        PlaylistManifestService.write(manifest, to: folder)

        let tracks = makeManager().loadTracks(from: folder)
        #expect(tracks.map(\.url.lastPathComponent) == ["volume-2.m4b", "volume-1.m4b"])
        #expect(tracks.map(\.isEnabled) == [false, true])
        let repaired = try #require(PlaylistManifestService.read(from: folder))
        #expect(repaired.tracks.map(\.file) == ["volume-2.m4b", "volume-1.m4b"])
        #expect(repaired.tracks.map(\.title) == ["Second volume", "First volume"])
        #expect(repaired.tracks.map(\.duration) == [200, 100])
        #expect(repaired.tracks.map(\.enabled) == [false, true])
        #expect(repaired.title == "Book")
        #expect(repaired.author == "Author")
        #expect(repaired.playbackState.lastTrackId == firstID)
        #expect(repaired.playbackState.lastPosition == (resumeWasOnReel ? 0 : 42))
        #expect(repaired.playbackState.speed == 1.5)
        #expect(repaired.playbackState.loopMode == "all")
        #expect(repaired.bookmarks?.first?.note == "Keep this")

        let manifestURL = folder.appending(path: PlaylistManifestService.fileName)
        let bytes = try Data(contentsOf: manifestURL)
        _ = makeManager().loadTracks(from: folder)
        #expect(try Data(contentsOf: manifestURL) == bytes)
    }

    @Test func singleBookAndReelsDoNotBecomeAMultiM4BBook() async throws {
        let folder = try makeFolder(files: [
            "book.m4b", "book.pronunciation-reel.m4b", "pronunciation-probe-reel.m4b",
        ])
        defer { try? FileManager.default.removeItem(at: folder) }

        let parsed = await M4BParser.parseFolder(folder)
        #expect(parsed == nil)
    }

    @Test func multiM4BChapterAggregationExcludesReels() async throws {
        let folder = try makeFolder(files: [
            "volume-1.m4b", "volume-2.m4b", "book.pronunciation-reel.m4b",
        ])
        defer { try? FileManager.default.removeItem(at: folder) }

        let parsed = try #require(await M4BParser.parseFolder(folder))
        #expect(parsed.books.map(\.url.lastPathComponent) == ["volume-1.m4b", "volume-2.m4b"])
    }

    @Test func libraryScannerIgnoresReelOnlyFolders() throws {
        let root = try makeFolder(files: [])
        defer { try? FileManager.default.removeItem(at: root) }
        let book = root.appending(path: "Book", directoryHint: .isDirectory)
        let review = root.appending(path: "Review", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: book, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: review, withIntermediateDirectories: true)
        try Data().write(to: book.appending(path: "book.m4b"))
        try Data().write(to: book.appending(path: "book.pronunciation-reel.m4b"))
        try Data().write(to: review.appending(path: "pronunciation-probe-reel.m4b"))

        let books = LibraryScanner.discoverBooks(in: root)
        #expect(books.map(\.folderURL.lastPathComponent) == ["Book"])
        #expect(books.first?.audioFiles.map(\.lastPathComponent) == ["book.m4b"])
    }

    @Test func documentWithOnlyAReelStillOpensAsAStudyDocument() throws {
        let folder = try makeFolder(files: ["book.epub", "book.pronunciation-reel.m4b"])
        defer { try? FileManager.default.removeItem(at: folder) }

        let route = try LibraryBookOpenDispatcher().route(
            for: LibraryOpenTarget(url: folder, scopedRoot: nil))
        #expect(
            route
                == .audiolessDocument(
                    documentURL: folder.appending(path: "book.epub"), audiobookIdentityURL: folder))
    }

    private func makeManager() -> PlaylistManager {
        PlaylistManager(
            state: PlaybackState(),
            persistence: Persistence(
                defaults: UserDefaults(suiteName: "AuxiliaryNarrationArtifactTests.\(UUID())")!,
                saveSecurityScopedBookmarkData: { _ in true },
                loadSecurityScopedBookmarkData: { nil }))
    }

    private func makeFolder(files: [String]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "auxiliary-audio-\(UUID())", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for file in files {
            try Data().write(to: folder.appending(path: file))
        }
        return folder
    }
}
