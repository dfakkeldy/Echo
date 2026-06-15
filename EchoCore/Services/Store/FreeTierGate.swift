import Foundation

@MainActor
@Observable
final class FreeTierGate {
    static let freeFlashcardCap = 20
    static let freeNarrationChaptersPerBook = 1

    private let entitlement: ProEntitlementProviding
    private var _flashcardCount: () -> Int = { 0 }
    private var _narratedChapters: (_ audiobookID: String) -> Int = { _ in 0 }

    /// Production init wires counts to the live DB; tests inject closures.
    init(
        entitlement: ProEntitlementProviding,
        flashcardCount: @escaping () -> Int = { 0 },
        narratedChapters: @escaping (_ audiobookID: String) -> Int = { _ in 0 }
    ) {
        self.entitlement = entitlement
        _flashcardCount = flashcardCount
        _narratedChapters = narratedChapters
    }

    /// Wire the DB-dependent count closures after database init.
    func wireCounts(
        flashcardCount: @escaping () -> Int,
        narratedChapters: @escaping (_ audiobookID: String) -> Int
    ) {
        _flashcardCount = flashcardCount
        _narratedChapters = narratedChapters
    }

    var isPro: Bool { entitlement.isPro }

    func canCreateFlashcards(adding count: Int) -> Bool {
        isPro || (_flashcardCount() + count) <= Self.freeFlashcardCap
    }

    func remainingFreeFlashcards() -> Int {
        isPro ? .max : max(0, Self.freeFlashcardCap - _flashcardCount())
    }

    /// `alreadyRenderedThisChapter` = the chapter already has a synthesized TrackRecord
    /// (idempotent re-render / voice change) — never blocked.
    func canRenderNarration(audiobookID: String, alreadyRenderedThisChapter: Bool) -> Bool {
        isPro || alreadyRenderedThisChapter
            || _narratedChapters(audiobookID) < Self.freeNarrationChaptersPerBook
    }
}
