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
