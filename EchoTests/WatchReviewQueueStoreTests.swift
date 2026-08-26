// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct WatchReviewQueueStoreTests {
    @Test func savesAndLoadsDueCards() throws {
        let testDefaults = try makeDefaults()
        let defaults = testDefaults.defaults
        defer { remove(testDefaults) }
        let cards = [
            WatchFlashcard(id: "card-1", frontText: "Front", backText: "Back"),
            WatchFlashcard(id: "card-2", frontText: "Second", backText: "Answer"),
        ]

        WatchReviewQueueStore.save(cards, to: defaults)

        #expect(WatchReviewQueueStore.load(from: defaults) == cards)
    }

    @Test func savingEmptyQueueClearsStaleCards() throws {
        let testDefaults = try makeDefaults()
        let defaults = testDefaults.defaults
        defer { remove(testDefaults) }
        WatchReviewQueueStore.save(
            [WatchFlashcard(id: "stale", frontText: "Old", backText: "Card")],
            to: defaults
        )

        WatchReviewQueueStore.save([], to: defaults)

        #expect(WatchReviewQueueStore.load(from: defaults).isEmpty)
    }

    @Test func removeCardPersistsRemainingQueue() throws {
        let testDefaults = try makeDefaults()
        let defaults = testDefaults.defaults
        defer { remove(testDefaults) }
        let remaining = WatchFlashcard(id: "card-2", frontText: "Second", backText: "Answer")
        WatchReviewQueueStore.save(
            [
                WatchFlashcard(id: "card-1", frontText: "Front", backText: "Back"),
                remaining,
            ],
            to: defaults
        )

        let updated = WatchReviewQueueStore.removeCard(id: "card-1", from: defaults)

        #expect(updated == [remaining])
        #expect(WatchReviewQueueStore.load(from: defaults) == [remaining])
    }

    @Test func invalidJSONLoadsAsEmptyQueue() throws {
        let testDefaults = try makeDefaults()
        let defaults = testDefaults.defaults
        defer { remove(testDefaults) }
        defaults.set("{", forKey: "watchReviewDueCardsJSON")

        #expect(WatchReviewQueueStore.load(from: defaults).isEmpty)
    }

    private func makeDefaults() throws -> (suiteName: String, defaults: UserDefaults) {
        let suiteName = "WatchReviewQueueStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return (suiteName: suiteName, defaults: defaults)
    }

    private func remove(_ testDefaults: (suiteName: String, defaults: UserDefaults)) {
        testDefaults.defaults.removePersistentDomain(forName: testDefaults.suiteName)
    }
}
