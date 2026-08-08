// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct ReaderIngestionReloadTrackerTests {
    @Test func laterAppearanceReloadsOnlyAnUnconsumedDurableGeneration() {
        var tracker = ReaderIngestionReloadTracker(completedGeneration: 4)

        #expect(tracker.requestReload(generation: 6, receivedNotification: false))
        let ticket = tracker.nextPendingReload()
        #expect(ticket?.generation == 6)
        tracker.complete(ticket)

        #expect(tracker.requestReload(generation: 6, receivedNotification: false) == false)
        #expect(tracker.nextPendingReload() == nil)
    }

    @Test func notificationAndGenerationBurstsCoalesceIntoOneLatestReload() {
        var tracker = ReaderIngestionReloadTracker(completedGeneration: 2)

        #expect(tracker.requestReload(generation: 2, receivedNotification: true))
        #expect(tracker.requestReload(generation: 3, receivedNotification: false))
        #expect(tracker.requestReload(generation: 3, receivedNotification: true))

        let ticket = tracker.nextPendingReload()
        #expect(ticket?.generation == 3)
        tracker.complete(ticket)
        #expect(tracker.nextPendingReload() == nil)
    }
}
