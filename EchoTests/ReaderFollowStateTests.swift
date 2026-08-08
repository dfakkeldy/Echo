// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct ReaderFollowStateTests {
    @Test func manualExplorationDetachesUntilResolvedReturn() {
        var state = ReaderFollowState.following
        state.detachForExploration()
        #expect(state == .exploring)

        #expect(state.completeReturn(targetResolved: false) == false)
        #expect(state == .exploring)

        #expect(state.completeReturn(targetResolved: true))
        #expect(state == .following)
    }

    @Test func queuedPlaybackScrollRequiresFollowingStateAndCurrentGeneration() {
        #expect(
            ReaderScrollPermission.allows(
                intent: .followPlayback,
                followState: .following,
                scheduledGeneration: 7,
                currentGeneration: 7
            )
        )
        #expect(
            ReaderScrollPermission.allows(
                intent: .followPlayback,
                followState: .exploring,
                scheduledGeneration: 7,
                currentGeneration: 7
            ) == false
        )
        #expect(
            ReaderScrollPermission.allows(
                intent: .followPlayback,
                followState: .following,
                scheduledGeneration: 7,
                currentGeneration: 8
            ) == false
        )
    }

    @Test func explicitReturnMayMoveWhileExploringButStillHonorsCancellation() {
        #expect(
            ReaderScrollPermission.allows(
                intent: .returnToCurrent,
                followState: .exploring,
                scheduledGeneration: 3,
                currentGeneration: 3
            )
        )
        #expect(
            ReaderScrollPermission.allows(
                intent: .returnToCurrent,
                followState: .exploring,
                scheduledGeneration: 3,
                currentGeneration: 4
            ) == false
        )
    }

    @Test func tableOfContentsNavigationIsAllowedWithoutResumingFollowing() {
        let state = ReaderFollowState.exploring

        #expect(
            ReaderScrollPermission.allows(
                intent: .tableOfContents,
                followState: state,
                scheduledGeneration: 3,
                currentGeneration: 3
            )
        )
        #expect(state == .exploring)
    }
}
