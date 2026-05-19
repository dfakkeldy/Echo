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
}
