// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS)
    import Foundation
    import Testing

    @testable import Echo

    /// Verifies that `WidgetStatePublisher` mirrors the playback snapshot into the
    /// shared App Group and triggers a widget reload. This is the seam the iOS app
    /// was missing: the watch stayed in sync over WatchConnectivity, but nothing on
    /// the app side ever wrote `AppGroupDefaults["isPlaying"]`, so the home-screen
    /// widget + Control Center toggle were frozen on stale state.
    @MainActor
    struct WidgetStatePublisherTests {

        /// An isolated in-memory defaults suite so tests never touch the real
        /// app-group store. Mirrors the `DatabaseService(inMemory:)` seam.
        private func makeDefaults(
            _ name: String = "WidgetStatePublisherTests-\(UUID().uuidString)"
        ) -> UserDefaults {
            let defaults = UserDefaults(suiteName: name)!
            defaults.removePersistentDomain(forName: name)
            return defaults
        }

        @Test("publishing a playing snapshot writes the widget keys and reloads once")
        func publishesPlayingState() {
            let defaults = makeDefaults()
            var reloadCount = 0
            let publisher = WidgetStatePublisher(defaults: defaults) { reloadCount += 1 }

            publisher.publish(
                context: [
                    "isPlaying": true,
                    "title": "Chapter 8",
                    "totalProgressFraction": 0.56,
                ],
                thumbnailData: Data([0xAB]))

            #expect(defaults.bool(forKey: "isPlaying") == true)
            #expect(defaults.string(forKey: "title") == "Chapter 8")
            #expect(defaults.double(forKey: "totalProgressFraction") == 0.56)
            #expect(defaults.data(forKey: "thumbnailData") == Data([0xAB]))
            #expect(reloadCount == 1)
        }

        @Test(
            "bookmark-intent keys are NOT mirrored — currentTime is cumulative and would mis-place per-track bookmarks"
        )
        func doesNotMirrorBookmarkIntentKeys() {
            let defaults = makeDefaults()
            let publisher = WidgetStatePublisher(defaults: defaults) {}

            publisher.publish(
                context: [
                    "isPlaying": true,
                    "currentTime": 4.0,
                    "folderKey": "/books/ebtc",
                    "trackId": "track-8",
                ],
                thumbnailData: nil)

            #expect(defaults.object(forKey: "currentTime") == nil)
            #expect(defaults.object(forKey: "folderKey") == nil)
            #expect(defaults.object(forKey: "trackId") == nil)
        }

        @Test("pausing clears a stale isPlaying flag so the widget shows Play")
        func publishesPausedState() {
            let defaults = makeDefaults()
            // Reproduce the bug's stale state: the widget's own toggle intent last
            // wrote isPlaying=true and nothing on the app side ever cleared it.
            defaults.set(true, forKey: "isPlaying")
            var reloaded = false
            let publisher = WidgetStatePublisher(defaults: defaults) { reloaded = true }

            publisher.publish(
                context: ["isPlaying": false, "title": "Chapter 8"],
                thumbnailData: nil)

            #expect(defaults.bool(forKey: "isPlaying") == false)
            #expect(reloaded == true)
        }

        @Test("a missing isPlaying value defaults to paused rather than crashing")
        func missingIsPlayingDefaultsToPaused() {
            let defaults = makeDefaults()
            defaults.set(true, forKey: "isPlaying")
            let publisher = WidgetStatePublisher(defaults: defaults) {}

            publisher.publish(context: ["title": "Chapter 8"], thumbnailData: nil)

            #expect(defaults.bool(forKey: "isPlaying") == false)
        }

        @Test("a nil thumbnail preserves the previously published artwork")
        func nilThumbnailPreservesExisting() {
            let defaults = makeDefaults()
            defaults.set(Data([0x01]), forKey: "thumbnailData")
            let publisher = WidgetStatePublisher(defaults: defaults) {}

            publisher.publish(context: ["isPlaying": true], thumbnailData: nil)

            #expect(defaults.data(forKey: "thumbnailData") == Data([0x01]))
        }
    }
#endif
