// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct ReaderIngestionReloadTrackerTests {
    @Test func laterAppearanceReloadsOnlyAnUnconsumedDurableGeneration() {
        var tracker = ReaderIngestionReloadTracker(completedGeneration: 4)

        let requestedInitialReload = tracker.requestReload(generation: 6, receivedNotification: false)
        #expect(requestedInitialReload)
        let ticket = tracker.nextPendingReload()
        #expect(ticket?.generation == 6)
        tracker.complete(ticket)

        let requestedDuplicateReload = tracker.requestReload(generation: 6, receivedNotification: false)
        #expect(requestedDuplicateReload == false)
        #expect(tracker.nextPendingReload() == nil)
    }

    @Test func notificationAndGenerationBurstsCoalesceIntoOneLatestReload() {
        var tracker = ReaderIngestionReloadTracker(completedGeneration: 2)

        let requestedNotificationReload = tracker.requestReload(generation: 2, receivedNotification: true)
        #expect(requestedNotificationReload)
        let requestedGenerationReload = tracker.requestReload(generation: 3, receivedNotification: false)
        #expect(requestedGenerationReload)
        let requestedBurstReload = tracker.requestReload(generation: 3, receivedNotification: true)
        #expect(requestedBurstReload)

        let ticket = tracker.nextPendingReload()
        #expect(ticket?.generation == 3)
        tracker.complete(ticket)
        #expect(tracker.nextPendingReload() == nil)
    }
}
