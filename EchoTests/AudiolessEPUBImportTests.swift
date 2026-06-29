// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// Swift Testing suites are structs, so resolving the test bundle's resources
/// needs a class anchor for `Bundle(for:)`.
private final class AudiolessFixtureLocator {}

/// Proves the audio-less EPUB path that `loadFolder` runs for a book with no
/// audio tracks: persist an audio-less book (`persistAudiobook(tracks: [])`),
/// then `EPUBAutoImportScanner.scanAndImportIfNeeded(chapters: [], duration: nil)`
/// — exactly the call `PlayerLoadingCoordinator` makes when `state.tracks` is
/// empty. The result is an audio-less `AudiobookRecord` whose EPUB text is
/// imported, including blocks at chapter index 0 (what on-device narration
/// reads). Runs below `PlayerModel`, avoiding the iOS-26-sim teardown crash.
@MainActor
@Suite struct AudiolessEPUBImportTests {

    @Test func audiolessABSDocumentTitleUsesPersistedMetadata() throws {
        let db = try DatabaseService(inMemory: ())
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let audiobookID = folder.absoluteString
        let expectedTitle = "Nonviolent Communication (Summary)"
        try AudiobookDAO(db: db.writer).save(
            AudiobookRecord(
                id: audiobookID,
                title: expectedTitle,
                author: "Marshall Rosenberg",
                duration: 0,
                fileCount: 0,
                addedAt: "2026-06-28T00:00:00Z",
                sourceType: "audiobookshelf",
                serverID: "server-1",
                remoteItemID: folder.lastPathComponent))

        let title = PlayerLoadingCoordinator.audiolessDocumentDisplayTitle(
            folderURL: folder, audiobookID: audiobookID, db: db)

        #expect(title == expectedTitle)
    }

    @Test func epubOnlyFolderImportsAsAudioLessBookWithChapterZeroBlocks() async throws {
        let db = try DatabaseService(inMemory: ())

        let fixture = try #require(
            Bundle(for: AudiolessFixtureLocator.self)
                .url(forResource: "minimal-book", withExtension: "epub"),
            "minimal-book.epub is missing from the EchoTests bundle resources")

        // Stage an EPUB-only folder, the way selecting the folder (or the EPUB
        // file, which normalises to its parent) presents it to loadFolder.
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("epubonly-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: fixture, to: folder.appendingPathComponent("minimal-book.epub"))
        // Empty alignment sidecar keeps the import offline/deterministic.
        try Data("[]".utf8).write(
            to: folder.appendingPathComponent("minimal-book.alignment.json"))
        let audiobookID = folder.absoluteString
        defer { cleanup(folder: folder, audiobookID: audiobookID) }

        // Reproduce loadFolder's no-audio branch exactly.
        TimelineIngestionService.persistAudiobook(
            db: db, folderURL: folder, tracks: [], duration: nil)
        let didImport = await EPUBAutoImportScanner.scanAndImportIfNeeded(
            folderURL: folder, databaseService: db, chapters: [], duration: nil)

        #expect(didImport)
        let book = try #require(try AudiobookDAO(db: db.writer).get(audiobookID))
        #expect(book.fileCount == 0)
        #expect(book.duration == 0)
        #expect(try TrackDAO(db: db.writer).tracks(for: audiobookID).isEmpty)
        #expect(try EPubBlockDAO(db: db.writer).blocks(for: audiobookID).count > 0)
        // Narration renders from chapter 0 — those blocks must exist, and must be
        // real body content (front matter is excluded from chapter numbering).
        let chapterZero = try EPubBlockDAO(db: db.writer).blocks(for: audiobookID, chapterIndex: 0)
        #expect(chapterZero.count > 0)
        #expect(chapterZero.allSatisfy { !$0.isFrontMatter })
    }

    /// Mirrors loadFolder's file-select branch: when an EPUB *file* is opened
    /// directly, it is imported via `importEPUBFile` using the file's own scope
    /// (no parent-folder enumeration), keyed on the normalised folder.
    @Test func directEPUBFileImportYieldsChapterZeroBlocks() async throws {
        let db = try DatabaseService(inMemory: ())
        let fixture = try #require(
            Bundle(for: AudiolessFixtureLocator.self)
                .url(forResource: "minimal-book", withExtension: "epub"),
            "minimal-book.epub is missing from the EchoTests bundle resources")

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("epubfile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let epubURL = folder.appendingPathComponent("minimal-book.epub")
        try FileManager.default.copyItem(at: fixture, to: epubURL)
        try Data("[]".utf8).write(
            to: folder.appendingPathComponent("minimal-book.alignment.json"))
        let audiobookID = folder.absoluteString
        defer { cleanup(folder: folder, audiobookID: audiobookID) }

        TimelineIngestionService.persistAudiobook(
            db: db, folderURL: folder, tracks: [], duration: nil)
        let didImport = await EPUBAutoImportScanner.importEPUBFile(
            epubURL: epubURL, audiobookID: audiobookID, databaseService: db,
            chapters: [], duration: nil, force: false)

        #expect(didImport)
        #expect(try EPubBlockDAO(db: db.writer).blocks(for: audiobookID, chapterIndex: 0).count > 0)
    }

    /// Reproduces the production FK failure (device log: "EPUB auto-import
    /// failed: SQLite error 19: FOREIGN KEY constraint failed - INSERT INTO
    /// epub_block(...)") that the two tests above miss because they pass the
    /// SAME key to `persistAudiobook` and the import.
    ///
    /// In `loadFolder`, when the user opens an EPUB *file* directly, the audiobook
    /// row was keyed off the raw picked `url` (the FILE) while blocks are keyed off
    /// the normalised parent directory (`state.folderURL`). `epub_block.audiobook_id`
    /// has a NOT NULL cascade FK to `audiobook(id)`, so when the only
    /// audiobook row is at the FILE key, the block INSERT under the PARENT key has
    /// no parent row and the FK rejects it — zero blocks import and narration falls
    /// back to a sample. This asserts that pre-fix split fails.
    @Test func keySplitFileAudiobookParentBlocksFailsFKImport() async throws {
        let db = try DatabaseService(inMemory: ())
        let fixture = try #require(
            Bundle(for: AudiolessFixtureLocator.self)
                .url(forResource: "minimal-book", withExtension: "epub"),
            "minimal-book.epub is missing from the EchoTests bundle resources")

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("epubsplit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let epubURL = folder.appendingPathComponent("minimal-book.epub")
        try FileManager.default.copyItem(at: fixture, to: epubURL)
        try Data("[]".utf8).write(
            to: folder.appendingPathComponent("minimal-book.alignment.json"))
        let parentKey = folder.absoluteString
        defer { cleanup(folder: folder, audiobookID: parentKey) }

        // Pre-fix loadFolder behaviour: audiobook row keyed to the FILE url...
        TimelineIngestionService.persistAudiobook(
            db: db, folderURL: epubURL, tracks: [], duration: nil)
        // ...but blocks keyed to the normalised PARENT url (importDocumentForAudiolessBook).
        let didImport = await EPUBAutoImportScanner.importEPUBFile(
            epubURL: epubURL, audiobookID: parentKey, databaseService: db,
            chapters: [], duration: nil, force: false)

        // The block INSERT hits the FK (no audiobook row at parentKey) and the
        // import's catch returns false; no blocks land under the parent key.
        #expect(didImport == false)
        #expect(try EPubBlockDAO(db: db.writer).blocks(for: parentKey).isEmpty)
    }

    /// Validates the fix's contract: persist the audiobook under the SAME
    /// canonical PARENT key that blocks use (post-fix `loadFolder` passes
    /// `state.folderURL` to `persistAudiobookToSQL`), then import. The FK resolves
    /// and chapter-0 blocks (what narration reads) exist under that key.
    @Test func canonicalKeyFileImportYieldsChapterZeroBlocks() async throws {
        let db = try DatabaseService(inMemory: ())
        let fixture = try #require(
            Bundle(for: AudiolessFixtureLocator.self)
                .url(forResource: "minimal-book", withExtension: "epub"),
            "minimal-book.epub is missing from the EchoTests bundle resources")

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("epubcanon-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let epubURL = folder.appendingPathComponent("minimal-book.epub")
        try FileManager.default.copyItem(at: fixture, to: epubURL)
        try Data("[]".utf8).write(
            to: folder.appendingPathComponent("minimal-book.alignment.json"))
        let parentKey = folder.absoluteString
        defer { cleanup(folder: folder, audiobookID: parentKey) }

        // Post-fix loadFolder behaviour: audiobook row under the PARENT key,
        // matching the block key.
        TimelineIngestionService.persistAudiobook(
            db: db, folderURL: folder, tracks: [], duration: nil)
        let didImport = await EPUBAutoImportScanner.importEPUBFile(
            epubURL: epubURL, audiobookID: parentKey, databaseService: db,
            chapters: [], duration: nil, force: false)

        #expect(didImport)
        #expect(try EPubBlockDAO(db: db.writer).blocks(for: parentKey, chapterIndex: 0).count > 0)
    }

    /// M4B regression guard: a single-file m4b open keys the audiobook AND its one
    /// track off the same `folderURL` argument inside `persistAudiobook`, so they
    /// always move together. After the fix both land under the PARENT key — the
    /// audiobook row exists and the track FK resolves (no split possible).
    @Test func singleFileM4BAudiobookAndTrackStayCoKeyed() throws {
        let db = try DatabaseService(inMemory: ())

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("m4bguard-\(UUID().uuidString)", isDirectory: true)
        let m4bURL = folder.appendingPathComponent("book.m4b")
        let parentKey = folder.absoluteString
        let track = Track(url: m4bURL, title: "book")

        TimelineIngestionService.persistAudiobook(
            db: db, folderURL: folder, tracks: [track], duration: 120)

        #expect(try AudiobookDAO(db: db.writer).get(parentKey) != nil)
        let tracks = try TrackDAO(db: db.writer).tracks(for: parentKey)
        #expect(tracks.count == 1)
        // The track's FK points at the audiobook row written in the same call.
        #expect(tracks.first?.audiobookID == parentKey)
    }

    /// Removes the staged folder plus the on-disk litter `importEPUBFile`
    /// creates outside it (extraction cache, image asset directory).
    private func cleanup(folder: URL, audiobookID: String) {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: folder)
        let safeID = SafeFileName.fromAudiobookID(audiobookID)
        if let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            try? fileManager.removeItem(
                at: caches.appendingPathComponent("EPUBUnpacked", isDirectory: true)
                    .appendingPathComponent(safeID, isDirectory: true))
        }
        if let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first
        {
            try? fileManager.removeItem(
                at: appSupport.appendingPathComponent("EPUBAssets", isDirectory: true)
                    .appendingPathComponent(safeID, isDirectory: true))
        }
    }
}
