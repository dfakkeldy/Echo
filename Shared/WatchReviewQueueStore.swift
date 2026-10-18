// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum WatchReviewQueueStore {
    private nonisolated static let key = "watchReviewDueCardsJSON"

    nonisolated static func load(from defaults: UserDefaults = AppGroupDefaults.shared) -> [WatchFlashcard] {
        guard let json = defaults.string(forKey: key) else { return [] }
        return decode(json) ?? []
    }

    nonisolated static func save(
        _ cards: [WatchFlashcard],
        to defaults: UserDefaults = AppGroupDefaults.shared
    ) {
        guard let json = encode(cards) else { return }
        defaults.set(json, forKey: key)
    }

    nonisolated static func removeCard(
        id: String,
        from defaults: UserDefaults = AppGroupDefaults.shared
    )
        -> [WatchFlashcard]
    {
        var cards = load(from: defaults)
        cards.removeAll { $0.id == id }
        save(cards, to: defaults)
        return cards
    }

    nonisolated static func encode(_ cards: [WatchFlashcard]) -> String? {
        guard let data = try? JSONEncoder().encode(cards) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated static func decode(_ json: String) -> [WatchFlashcard]? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([WatchFlashcard].self, from: data)
    }
}
