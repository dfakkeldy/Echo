import Foundation
import GRDB

/// A pre-computed snapshot of watch state data that is expensive to compute
/// (e.g. due flashcards requiring a full GRDB table scan). Updated
/// asynchronously at mutation points so the watch message hot path never
/// touches the database.
struct WatchStateSnapshot {
    /// JSON-encoded array of `WatchFlashcard`, or nil when no cards are due.
    var dueCardsJSON: String?
}

/// Repository boundary around watch state data derived from GRDB.
/// Owns a cached `WatchStateSnapshot` and refreshes it on a background
/// queue so that `PlayerModel.watchStateContext()` — called synchronously
/// on every watch crown rotation — can read pre-serialized data without
/// touching the database.
final class WatchStateRepository {
    private var snapshot = WatchStateSnapshot()
    private let daoProvider: () -> FlashcardDAO?

    init(daoProvider: @escaping () -> FlashcardDAO?) {
        self.daoProvider = daoProvider
    }

    /// Returns the most recently cached snapshot. Always O(1), no I/O.
    func currentSnapshot() -> WatchStateSnapshot {
        snapshot
    }

    /// Refreshes the due-cards cache asynchronously on a background queue.
    /// Call after any flashcard mutation (grade, create, import) or when
    /// the active audiobook changes.
    func refreshDueCards() {
        Task.detached(priority: .utility) { [weak self] in
            guard let self, let dao = self.daoProvider() else { return }
            let cards = (try? dao.allDueCards()) ?? []
            let json = Self.encodeDueCards(cards)
            await MainActor.run {
                self.snapshot = WatchStateSnapshot(dueCardsJSON: json)
            }
        }
    }

    private static func encodeDueCards(_ cards: [Flashcard]) -> String? {
        guard !cards.isEmpty else { return nil }
        let watchCards = cards.map {
            WatchFlashcard(id: $0.id, frontText: $0.frontText, backText: $0.backText)
        }
        guard let data = try? JSONEncoder().encode(watchCards),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }
}
