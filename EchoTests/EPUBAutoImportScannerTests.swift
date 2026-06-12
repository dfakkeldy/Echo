import Testing
import Foundation
import GRDB
@testable import Echo

/// Bundle anchor: Swift Testing suites are structs, so locating the test
/// bundle's resources needs a dedicated class for `Bundle(for:)`.
private final class FixtureBundleLocator {}

/// Exercises the EPUB auto-import path end-to-end with a real (minimal) EPUB
/// archive: `EchoTests/Fixtures/minimal-book.epub` — two spine chapters, each
/// a heading plus paragraphs.
///
/// The staged folder always includes an empty `minimal-book.alignment.json`
/// sidecar so the import takes the sidecar branch instead of the CloudKit
/// anchor lookup, keeping these tests offline and deterministic.
@MainActor
struct EPUBAutoImportScannerTests {

    /// Two chapters matching the fixture EPUB's spine, for chapter-index assignment.
    private var fixtureChapters: [Chapter] {
        [
            Chapter(index: 0, title: "Chapter One", startSeconds: 0, endSeconds: 1800, isEnabled: true),
            Chapter(index: 1, title: "Chapter Two", startSeconds: 1800, endSeconds: 3600, isEnabled: true),
        ]
    }

    /// Stages the fixture EPUB (plus empty alignment sidecar) in a unique
    /// audiobook folder backed by an in-memory database.
    private func makeAudiobookFolder() throws -> (db: DatabaseService, folderURL: URL, epubURL: URL, audiobookID: String) {
        let db = try DatabaseService(inMemory: ())
        let folderURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)

        let fixtureURL = try #require(
            Bundle(for: FixtureBundleLocator.self)
                .url(forResource: "minimal-book", withExtension: "epub"),
            "minimal-book.epub is missing from the EchoTests bundle resources"
        )
        let epubURL = folderURL.appendingPathComponent("minimal-book.epub")
        try FileManager.default.copyItem(at: fixtureURL, to: epubURL)
        try Data("[]".utf8).write(to: folderURL.appendingPathComponent("minimal-book.alignment.json"))

        let audiobookID = folderURL.absoluteString
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES (?, 'Fixture', 3600)",
                arguments: [audiobookID]
            )
        }
        return (db, folderURL, epubURL, audiobookID)
    }

    /// Removes the staged folder plus the on-disk litter `importEPUBFile`
    /// creates outside it (extraction cache, image asset directory).
    private func cleanup(folderURL: URL, audiobookID: String) {
        try? FileManager.default.removeItem(at: folderURL)
        let safeID = SafeFileName.fromAudiobookID(audiobookID)
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            try? FileManager.default.removeItem(
                at: caches
                    .appendingPathComponent("EPUBUnpacked", isDirectory: true)
                    .appendingPathComponent(safeID, isDirectory: true)
            )
        }
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            try? FileManager.default.removeItem(
                at: appSupport
                    .appendingPathComponent("EPUBAssets", isDirectory: true)
                    .appendingPathComponent(safeID, isDirectory: true)
            )
        }
    }

    @Test func importingValidEPUBReturnsTrueAndCreatesBlocks() async throws {
        let (db, folderURL, epubURL, audiobookID) = try makeAudiobookFolder()
        defer { cleanup(folderURL: folderURL, audiobookID: audiobookID) }

        let didImport = await EPUBAutoImportScanner.importEPUBFile(
            epubURL: epubURL,
            audiobookID: audiobookID,
            databaseService: db,
            chapters: fixtureChapters,
            duration: 3600
        )

        #expect(didImport == true)

        let blocks = try EPubBlockDAO(db: db.writer).visibleBlocks(for: audiobookID)
        #expect(!blocks.isEmpty)
        // Both fixture spine items contribute blocks (a heading plus paragraphs each).
        #expect(Set(blocks.map(\.spineIndex)).count == 2)
    }

    @Test func reimportWithoutForceIsSkippedAndReturnsFalse() async throws {
        let (db, folderURL, epubURL, audiobookID) = try makeAudiobookFolder()
        defer { cleanup(folderURL: folderURL, audiobookID: audiobookID) }

        let first = await EPUBAutoImportScanner.importEPUBFile(
            epubURL: epubURL, audiobookID: audiobookID, databaseService: db,
            chapters: fixtureChapters, duration: 3600
        )
        let second = await EPUBAutoImportScanner.importEPUBFile(
            epubURL: epubURL, audiobookID: audiobookID, databaseService: db,
            chapters: fixtureChapters, duration: 3600
        )

        #expect(first == true)
        #expect(second == false, "already-imported guard must report no import so callers skip timeline re-ingestion")
    }

    @Test func ingestAfterImportCreatesEPUBLinkedTimelineRows() async throws {
        let (db, folderURL, epubURL, audiobookID) = try makeAudiobookFolder()
        defer { cleanup(folderURL: folderURL, audiobookID: audiobookID) }

        let didImport = await EPUBAutoImportScanner.importEPUBFile(
            epubURL: epubURL, audiobookID: audiobookID, databaseService: db,
            chapters: fixtureChapters, duration: 3600
        )
        #expect(didImport == true)

        // The re-ingestion PlayerLoadingCoordinator performs when didImport is true.
        await TimelineIngestionService.ingestItems(
            db: db,
            audiobookID: audiobookID,
            audioURL: folderURL.appendingPathComponent("audio.m4b"),
            chapters: fixtureChapters,
            transcription: [],
            enhancedTranscription: [],
            folderURL: folderURL
        )

        let items = try TimelineDAO(db: db.writer).items(for: audiobookID)
        let blocks = try EPubBlockDAO(db: db.writer).visibleBlocks(for: audiobookID)

        let epubLinked = items.filter { $0.epubBlockID != nil }
        #expect(!epubLinked.isEmpty)

        // Every visible block is represented in the rebuilt timeline.
        let linkedIDs = Set(epubLinked.compactMap(\.epubBlockID))
        for block in blocks {
            #expect(linkedIDs.contains(block.id), "missing timeline row for block \(block.id)")
        }
    }
}
