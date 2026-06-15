import Testing

@testable import Echo

@MainActor
struct FreeTierGateTests {
    private final class FakeEntitlement: ProEntitlementProviding {
        var isPro: Bool
        init(_ v: Bool) { isPro = v }
    }

    @Test func proCanAlwaysCreate() {
        let gate = FreeTierGate(entitlement: FakeEntitlement(true), flashcardCount: { 999 })
        #expect(gate.canCreateFlashcards(adding: 100))
    }

    @Test func freeUserCappedAtTwenty() {
        let gate = FreeTierGate(entitlement: FakeEntitlement(false), flashcardCount: { 19 })
        #expect(gate.canCreateFlashcards(adding: 1))  // 19+1 = 20, allowed (the 20th)
        let full = FreeTierGate(entitlement: FakeEntitlement(false), flashcardCount: { 20 })
        #expect(!full.canCreateFlashcards(adding: 1))  // would be 21, blocked
    }

    @Test func freeNarrationOneChapterPerBook() {
        let none = FreeTierGate(entitlement: FakeEntitlement(false), narratedChapters: { _ in 0 })
        #expect(none.canRenderNarration(audiobookID: "b", alreadyRenderedThisChapter: false))
        let one = FreeTierGate(entitlement: FakeEntitlement(false), narratedChapters: { _ in 1 })
        #expect(!one.canRenderNarration(audiobookID: "b", alreadyRenderedThisChapter: false))
        // re-rendering an already-narrated chapter (voice change) is always allowed:
        #expect(one.canRenderNarration(audiobookID: "b", alreadyRenderedThisChapter: true))
    }
}
