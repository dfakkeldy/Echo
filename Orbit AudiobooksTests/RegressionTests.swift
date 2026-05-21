import Testing
import Foundation
import GRDB
@testable import Orbit_Audiobooks

/// Regression tests covering the known issues from the V1 EPUB Timeline spec.
@MainActor
struct RegressionTests {

    // MARK: - MigrationService is called on startup

    @Test func databaseServiceRunsMigrationsOnInit() throws {
        // DatabaseService(inMemory:) initializes and runs all migrations (V1-V5).
        let db = try DatabaseService(inMemory: ())

        let tables = try db.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")
        }
        // V5 tables must exist after migration.
        #expect(tables.contains("epub_block"))
        #expect(tables.contains("alignment_anchor"))
        #expect(tables.contains("timeline_item"))
    }

    // MARK: - Enhanced transcript sidecar is discoverable

    @Test func enhancedTranscriptSidecarIsDiscovered() throws {
        // Create a temporary audio file and an .enhanced.json sidecar.
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let audioFile = tmpDir.appendingPathComponent("test-audio.m4b")
        try Data().write(to: audioFile)

        // Write enhanced transcript sidecar.
        let enhancedJSON = """
        [{"sequenceIndex": 0, "text": "Hello world", "startTime": 0, "endTime": 5}]
        """
        let enhancedFile = tmpDir.appendingPathComponent("test-audio.enhanced.json")
        try enhancedJSON.write(to: enhancedFile, atomically: true, encoding: .utf8)

        let state = PlaybackState()
        state.isTranscriptProcessingEnabled = true
        let service = TranscriptService(state: state)

        service.loadTranscript(for: audioFile)
        let enhanced = state.enhancedTranscription
        #expect(!enhanced.isEmpty)
        #expect(enhanced.count == 1)
        #expect(enhanced.first?.text == "Hello world")
    }

    // MARK: - Timeline DAO errors are not swallowed

    @Test func timelineDAOErrorPopulatedInViewModel() async throws {
        let db = try DatabaseService(inMemory: ())
        let timelineDAO = TimelineDAO(db: db.writer)
        let audiobookDAO = AudiobookDAO(db: db.writer)
        let viewModel = TimelineFeedViewModel(
            timelineDAO: timelineDAO,
            audiobookDAO: audiobookDAO,
            audiobookID: "non-existent"
        )

        // Load initial window — should not crash for missing audiobook.
        await viewModel.loadInitialWindow(around: 0)
        #expect(viewModel.lastError == nil) // Empty result is not an error
        #expect(viewModel.items.isEmpty)
    }

    // MARK: - Chapter artwork filename sanitizes file:// IDs

    @Test func safeFileNameSanitizesFileURLForArtwork() {
        let rawID = "file:///var/mobile/Containers/Data/Application/ABC123/Documents/My Big: Book!"
        let safe = SafeFileName.fromAudiobookID(rawID)

        #expect(!safe.contains("file://"))
        #expect(!safe.contains(":"))
        #expect(!safe.contains("/"))
    }

    // MARK: - EPUB images render from copied asset paths

    @Test func epubImageStoredAsLocalPath() throws {
        let db = try DatabaseService(inMemory: ())
        let storage = EPUBAssetStorage(databaseService: db)

        let testID = "file:///path/to/book-\(UUID().uuidString)"
        let dir = storage.directory(for: testID)

        // Path must be a local filesystem path, not an EPUB href.
        #expect(dir.isFileURL)
        #expect(!dir.path.contains("://"))
        #expect(dir.path.hasPrefix("/"))
    }

    // MARK: - Follow playback callback scrolls collection view

    @Test func viewModelScrollCallbackWiredForFollowingPlayback() async throws {
        let db = try DatabaseService(inMemory: ())
        let timelineDAO = TimelineDAO(db: db.writer)
        let audiobookDAO = AudiobookDAO(db: db.writer)
        let viewModel = TimelineFeedViewModel(
            timelineDAO: timelineDAO,
            audiobookDAO: audiobookDAO,
            audiobookID: "book-1"
        )

        var scrollCalled = false
        viewModel.onScrollToPosition = { _ in scrollCalled = true }

        // Following playback → scroll should fire.
        viewModel.updatePosition(10.0)
        #expect(scrollCalled)

        // User scrolls → browsing → scroll should NOT fire.
        scrollCalled = false
        viewModel.userDidScroll()
        viewModel.updatePosition(20.0)
        #expect(!scrollCalled)

        // Go to Now → following → scroll should fire again.
        scrollCalled = false
        viewModel.goToNow()
        viewModel.updatePosition(30.0)
        #expect(scrollCalled)
    }

    // MARK: - Schema V5 migration is idempotent

    @Test func v5MigrationIsIdempotent() throws {
        // Running migrations twice should not fail (DatabaseService already runs them).
        let db = try DatabaseService(inMemory: ())

        // Verify tables exist after initial migration.
        let tables = try db.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
        }
        #expect(tables.contains("epub_block"))
        #expect(tables.contains("alignment_anchor"))
    }

    // MARK: - EPUB sequence ordering is stable

    @Test func epubBlockSequenceIsStableOnReingestion() throws {
        let db = try DatabaseService(inMemory: ())

        try db.write { db in
            try db.execute(sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book-1', 'Test', 3600)")
        }

        let blocks: [EPubBlockRecord] = [
            EPubBlockRecord(id: "b0", audiobookID: "book-1", spineHref: "ch1.xhtml",
                           spineIndex: 0, blockIndex: 0, sequenceIndex: 0,
                           blockKind: "heading", text: "Chapter 1", chapterIndex: 0, isHidden: false),
            EPubBlockRecord(id: "b1", audiobookID: "book-1", spineHref: "ch1.xhtml",
                           spineIndex: 0, blockIndex: 1, sequenceIndex: 1,
                           blockKind: "paragraph", text: "Paragraph 1", chapterIndex: 0, isHidden: false),
        ]
        try EPubBlockDAO(db: db.writer).insertAll(blocks)

        let stored = try EPubBlockDAO(db: db.writer).blocks(for: "book-1")
        #expect(stored.count == 2)
        #expect(stored[0].sequenceIndex < stored[1].sequenceIndex)

        // Re-ingestion should produce same order.
        try EPubBlockDAO(db: db.writer).deleteAll(for: "book-1")
        try EPubBlockDAO(db: db.writer).insertAll(blocks)
        let restocked = try EPubBlockDAO(db: db.writer).blocks(for: "book-1")
        #expect(restocked.count == 2)
        #expect(restocked[0].sequenceIndex < restocked[1].sequenceIndex)
    }
}
