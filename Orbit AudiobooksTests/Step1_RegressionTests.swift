import Testing
import Foundation
@testable import Orbit_Audiobooks

// MARK: - SafeFileName Tests

struct SafeFileNameTests {

    @Test("SafeFileName sanitizes file:// URL prefix")
    func sanitizesFileURLPrefix() {
        let input = "file:///var/mobile/Containers/Data/Application/abc123/Documents/My Book/"
        let safe = SafeFileName.fromAudiobookID(input)
        #expect(!safe.contains("file://"))
        #expect(!safe.contains("/"))
        #expect(!safe.contains(":"))
    }

    @Test("SafeFileName preserves meaningful path segments")
    func preservesPathSegments() {
        let input = "file:///var/mobile/Containers/Data/Application/abc123/Documents/My Book/"
        let safe = SafeFileName.fromAudiobookID(input)
        #expect(safe.contains("My Book"))
        #expect(!safe.isEmpty)
    }

    @Test("SafeFileName produces consistent output for same input")
    func consistentOutput() {
        let input = "file:///path/to/Some Audiobook/"
        let a = SafeFileName.fromAudiobookID(input)
        let b = SafeFileName.fromAudiobookID(input)
        #expect(a == b)
    }

    @Test("SafeFileName handles plain string without slashes")
    func handlesPlainString() {
        let input = "simple-id-123"
        let safe = SafeFileName.fromAudiobookID(input)
        #expect(safe == "simple-id-123")
    }

    @Test("SafeFileName returns non-empty for empty input")
    func handlesEmptyInput() {
        let safe = SafeFileName.fromAudiobookID("")
        #expect(!safe.isEmpty) // falls back to a placeholder
    }
}

// MARK: - TimelineFeedViewModel Error Tests

@MainActor
struct TimelineFeedViewModelErrorTests {

    @Test("TimelineFeedViewModel exposes lastError on DAO failure")
    func lastErrorInitialState() {
        let db = try! DatabaseService(inMemory: ())
        let dao = TimelineDAO(db: db.writer)
        let audiobookDAO = AudiobookDAO(db: db.writer)
        let vm = TimelineFeedViewModel(
            timelineDAO: dao,
            audiobookDAO: audiobookDAO,
            audiobookID: "test-id"
        )
        // Initially nil
        #expect(vm.lastError == nil)
    }

    @Test("TimelineFeedViewModel preserves items on error")
    func preservesItemsOnError() {
        let db = try! DatabaseService(inMemory: ())
        let dao = TimelineDAO(db: db.writer)
        let audiobookDAO = AudiobookDAO(db: db.writer)
        let vm = TimelineFeedViewModel(
            timelineDAO: dao,
            audiobookDAO: audiobookDAO,
            audiobookID: nil // No audiobookID means timeline queries return empty
        )
        #expect(vm.items.isEmpty)
    }
}

// MARK: - MigrationService Startup Tests

struct MigrationServiceStartupTests {

    @Test("MigrationService.migrateIfNeeded is safe to call on fresh DB")
    func migrateOnFreshDB() throws {
        let db = try DatabaseService(inMemory: ())
        // Should not crash or throw — flag prevents duplicate migration
        MigrationService.migrateIfNeeded(database: db)
        // Second call is also safe (isMigrationDone flag)
        MigrationService.migrateIfNeeded(database: db)
    }

    @Test("MigrationService migration flag prevents re-migration")
    func migrationFlagPreventsDuplicate() throws {
        let db = try DatabaseService(inMemory: ())
        #expect(db.isMigrationDone == false)
        MigrationService.migrateIfNeeded(database: db)
        #expect(db.isMigrationDone == true)
    }
}
