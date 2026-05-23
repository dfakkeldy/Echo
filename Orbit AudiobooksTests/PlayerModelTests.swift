import Testing
import Foundation
@testable import Orbit_Audiobooks

@MainActor
struct PlayerModelTests {

    @Test("PlayerModel initializes with default services")
    func initDefaults() {
        let model = PlayerModel()

        #expect(model.isPlaying == false)
        #expect(model.currentTitle == "No track selected")
        #expect(model.currentPlaybackTime == 0)
    }

    @Test("MockBookmarkStore tracks additions")
    func mockBookmarkStoreAdd() {
        let store = MockBookmarkStore()
        let bookmark = store.addBookmark(at: 120.0, trackId: nil, folderKey: "test-key")

        #expect(store.bookmarks.count == 1)
        #expect(bookmark.timestamp == 120.0)
    }

    @Test("MockBookmarkStore tracks deletions")
    func mockBookmarkStoreDelete() {
        let store = MockBookmarkStore()
        let bookmark = store.addBookmark(at: 60.0, trackId: nil, folderKey: "test-key")

        store.deleteBookmark(id: bookmark.id)

        #expect(store.bookmarks.isEmpty)
        #expect(store.deletedBookmarkIDs.contains(bookmark.id))
    }

    @Test("MockPlaybackController tracks play/pause")
    func mockPlaybackControllerPlayPause() {
        let controller = MockPlaybackController()

        controller.play()
        #expect(controller.isPlaying == true)
        #expect(controller.playCallCount == 1)

        controller.pause()
        #expect(controller.isPlaying == false)
        #expect(controller.pauseCallCount == 1)
    }

    @Test("MockPlaybackController skip advances time by 30s")
    func mockPlaybackControllerSkip() {
        let controller = MockPlaybackController()
        controller.currentTime = 150

        _ = controller.skipForward30()
        #expect(controller.currentTime == 180)

        _ = controller.skipBackward30()
        #expect(controller.currentTime == 150)
    }

    @Test("MockSleepTimerManager tracks timer lifecycle")
    func mockSleepTimerManagerLifecycle() {
        let timer = MockSleepTimerManager()

        timer.setTimer(.minutes(30))
        #expect(timer.setTimerCallCount == 1)
        #expect(timer.setTimerModes.contains(.minutes(30)))

        timer.cancel()
        #expect(timer.cancelCallCount == 1)
        #expect(timer.mode == .off)
    }

    @Test("MockSettingsManager has correct defaults")
    func mockSettingsManagerDefaults() {
        let settings = MockSettingsManager()

        #expect(settings.appFont == "Lexend")
        #expect(settings.isDarkMode == true)
    }

    @Test("PlayerModel importEPUB preserves the source EPUB file when imported from the same folder")
    func importEPUBPreservesSourceWhenSameFolder() throws {
        let model = PlayerModel()
        let db = try DatabaseService(inMemory: ())
        model.databaseService = db

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        model.folderURL = tmpDir

        // Create a fake EPUB file inside the folder
        let epubURL = tmpDir.appendingPathComponent("test.epub")
        try Data("fake epub content".utf8).write(to: epubURL)

        // Verify the file exists initially
        #expect(FileManager.default.fileExists(atPath: epubURL.path))

        // Trigger importEPUB from the exact file location
        model.importEPUB(from: epubURL)

        // Verify the file was NOT deleted!
        #expect(FileManager.default.fileExists(atPath: epubURL.path))
    }

    @Test("PlayerModel importEPUB preserves other EPUBs and copies new one when imported from outside folder")
    func importEPUBPreservesOtherEPUBs() throws {
        let model = PlayerModel()
        let db = try DatabaseService(inMemory: ())
        model.databaseService = db

        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        model.folderURL = tmpDir

        // Create an existing epub in the folder (which should NOT be deleted)
        let oldEpubURL = tmpDir.appendingPathComponent("old.epub")
        try Data("old epub content".utf8).write(to: oldEpubURL)

        // Create source epub outside the folder
        let outerDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: outerDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outerDir) }

        let sourceEpubURL = outerDir.appendingPathComponent("new.epub")
        try Data("new epub content".utf8).write(to: sourceEpubURL)

        // Trigger importEPUB
        model.importEPUB(from: sourceEpubURL)

        // Verify old EPUB is NOT deleted
        #expect(FileManager.default.fileExists(atPath: oldEpubURL.path))

        // Verify new EPUB is copied into folder
        let destinationURL = tmpDir.appendingPathComponent("new.epub")
        #expect(FileManager.default.fileExists(atPath: destinationURL.path))

        // Verify source EPUB at original location is NOT deleted
        #expect(FileManager.default.fileExists(atPath: sourceEpubURL.path))
    }
}

