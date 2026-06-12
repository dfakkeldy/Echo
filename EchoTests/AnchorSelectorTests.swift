import Foundation
import Testing
@testable import Echo

struct AnchorSelectorTests {

    private func cand(_ id: String, _ time: TimeInterval, run: Int) -> TokenDTW.AnchorCandidate {
        TokenDTW.AnchorCandidate(blockID: id, time: time, exactRunLength: run, firstMatchTokenIndex: 0)
    }

    @Test func dropsCandidatesBelowMinimumRunLength() {
        let selected = AnchorSelector.select(
            candidates: [cand("b-1", 10, run: 2), cand("b-2", 20, run: 3)],
            minRunLength: 3
        )
        #expect(selected.map(\.blockID) == ["b-2"])
    }

    @Test func keepsAlreadyMonotonicCandidates() {
        let candidates = [cand("b-1", 10, run: 5), cand("b-2", 20, run: 4), cand("b-3", 30, run: 6)]
        #expect(AnchorSelector.select(candidates: candidates).map(\.blockID) == ["b-1", "b-2", "b-3"])
    }

    @Test func dropsWeakTimeRegression() {
        // b-2 jumps *backwards* in time with a weaker run than its
        // predecessor: it is the suspect and must go.
        let candidates = [cand("b-1", 100, run: 5), cand("b-2", 90, run: 3), cand("b-3", 101, run: 4)]
        #expect(AnchorSelector.select(candidates: candidates).map(\.blockID) == ["b-1", "b-3"])
    }

    @Test func strongRegressionEvictsWeakPredecessor() {
        // Here the *predecessor* was the bad match: a much stronger run
        // arrives earlier in time, so the weak b-1 gets evicted.
        let candidates = [cand("b-1", 100, run: 3), cand("b-2", 90, run: 8), cand("b-3", 95, run: 4)]
        #expect(AnchorSelector.select(candidates: candidates).map(\.blockID) == ["b-2", "b-3"])
    }

    @Test func nearTiesWithinEpsilonAreNotRegressions() {
        let candidates = [cand("b-1", 100.0, run: 3), cand("b-2", 99.9, run: 3)]
        #expect(AnchorSelector.select(candidates: candidates).count == 2)
    }
}
