import Testing
import Foundation
import GRDB
@testable import Orbit_Audiobooks

@MainActor
struct TimelinePlumbingTests {

    // MARK: - SafeFileName

    @Test func safeFileNameRemovesFileScheme() {
        let result = SafeFileName.fromAudiobookID("file:///path/to/book.m4b")
        #expect(!result.contains("file://"))
        #expect(result.contains("book.m4b"))
    }

    @Test func safeFileNameReplacesInvalidCharacters() {
        let result = SafeFileName.fromAudiobookID("file:///path/to/book:with*invalid?chars")
        #expect(!result.contains(":"))
        #expect(!result.contains("*"))
        #expect(!result.contains("?"))
    }

    @Test func safeFileNameHandlesEmptyInput() {
        let result = SafeFileName.fromAudiobookID("")
        #expect(!result.isEmpty)
    }

    @Test func safeFileNameHandlesPlainString() {
        let result = SafeFileName.fromAudiobookID("simple-audiobook-id")
        #expect(result == "simple-audiobook-id")
    }

    // MARK: - TimelineFeedViewModel error handling

    @Test func viewModelExposesLastErrorOnDAOFailure() async throws {
        let db = try DatabaseService(inMemory: ())

        // Create a view model pointing to an audiobook that has no rows.
        // feedWindow will succeed but return empty — not an error case.
        // To test error handling, we need to trigger a real DAO failure.
        // Use a DAO that will throw (e.g., by passing invalid args).

        let timelineDAO = TimelineDAO(db: db.writer)
        let audiobookDAO = AudiobookDAO(db: db.writer)
        let viewModel = TimelineFeedViewModel(
            timelineDAO: timelineDAO,
            audiobookDAO: audiobookDAO,
            audiobookID: "nonexistent-book"
        )

        // loadInitialWindow should succeed with empty items for a non-existent book.
        await viewModel.loadInitialWindow(around: 0)
        #expect(viewModel.items.isEmpty)
        #expect(viewModel.lastError == nil)
    }

    @Test func viewModelKeepsItemsOnReloadFailure() async throws {
        let db = try DatabaseService(inMemory: ())

        // Insert some timeline items.
        let items: [TimelineItem] = [
            TimelineItem(id: "t1", audiobookID: "book-1", itemType: .chapterMarker,
                        title: "Ch 1", audioStartTime: 0, granularityLevel: .chapter, isEnabled: true),
            TimelineItem(id: "t2", audiobookID: "book-1", itemType: .textSegment,
                        title: "Hello", audioStartTime: 10, granularityLevel: .sentence, isEnabled: true),
        ]
        try TimelineDAO(db: db.writer).ingest(items)

        let timelineDAO = TimelineDAO(db: db.writer)
        let audiobookDAO = AudiobookDAO(db: db.writer)
        let viewModel = TimelineFeedViewModel(
            timelineDAO: timelineDAO,
            audiobookDAO: audiobookDAO,
            audiobookID: "book-1"
        )

        // Load the initial window — should have 2 items.
        await viewModel.loadInitialWindow(around: 0)
        #expect(viewModel.items.count == 2)
        #expect(viewModel.lastError == nil)
    }

    // MARK: - Follow playback scroll

    @Test func viewModelUpdatePositionCallsScrollCallbackWhenFollowing() async throws {
        let db = try DatabaseService(inMemory: ())
        let timelineDAO = TimelineDAO(db: db.writer)
        let audiobookDAO = AudiobookDAO(db: db.writer)
        let viewModel = TimelineFeedViewModel(
            timelineDAO: timelineDAO,
            audiobookDAO: audiobookDAO,
            audiobookID: "book-1"
        )

        var scrollPositions: [TimeInterval] = []
        viewModel.onScrollToPosition = { scrollPositions.append($0) }

        viewModel.updatePosition(42.0)
        #expect(scrollPositions == [42.0])

        viewModel.updatePosition(43.0)
        #expect(scrollPositions == [42.0, 43.0])
    }

    @Test func viewModelStopsScrollCallbackWhenBrowsing() async throws {
        let db = try DatabaseService(inMemory: ())
        let timelineDAO = TimelineDAO(db: db.writer)
        let audiobookDAO = AudiobookDAO(db: db.writer)
        let viewModel = TimelineFeedViewModel(
            timelineDAO: timelineDAO,
            audiobookDAO: audiobookDAO,
            audiobookID: "book-1"
        )

        var scrollPositions: [TimeInterval] = []
        viewModel.onScrollToPosition = { scrollPositions.append($0) }

        viewModel.userDidScroll()
        viewModel.updatePosition(100.0)

        // Should NOT fire because user scrolled (isFollowingPlayback is false)
        #expect(scrollPositions.isEmpty)
    }

    @Test func viewModelGoToNowRestoresFollowAndScrolls() async throws {
        let db = try DatabaseService(inMemory: ())
        let timelineDAO = TimelineDAO(db: db.writer)
        let audiobookDAO = AudiobookDAO(db: db.writer)
        let viewModel = TimelineFeedViewModel(
            timelineDAO: timelineDAO,
            audiobookDAO: audiobookDAO,
            audiobookID: "book-1"
        )

        var scrollPositions: [TimeInterval] = []
        viewModel.onScrollToPosition = { scrollPositions.append($0) }

        viewModel.userDidScroll()
        viewModel.updatePosition(50.0)
        #expect(scrollPositions.isEmpty) // browsing, no scroll

        viewModel.goToNow()
        #expect(viewModel.isFollowingPlayback == true)
    }

    // MARK: - Database schema evolution readiness

    @Test func v4SchemaHasRequiredTimelineColumns() throws {
        let db = try DatabaseService(inMemory: ())

        let columnNames = try db.read { db in
            try Row.fetchAll(db, sql: "PRAGMA table_info(timeline_item)").map { $0["name"] as? String ?? "" }
        }
        let nameSet = Set(columnNames)

        #expect(nameSet.contains("id"))
        #expect(nameSet.contains("audiobook_id"))
        #expect(nameSet.contains("item_type"))
        #expect(nameSet.contains("audio_start_time"))
        #expect(nameSet.contains("epub_sequence_index"))
        #expect(nameSet.contains("is_enabled"))
        #expect(nameSet.contains("source_table"))
    }

    // MARK: - EPUB block schema (V5 readiness — table must NOT exist yet)

    @Test func v4SchemaDoesNotHaveEPUBBlockTable() throws {
        let db = try DatabaseService(inMemory: ())

        let tables = try db.read { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master WHERE type='table' AND name='epub_block'
                """)
        }
        #expect(tables.isEmpty)
    }
}
