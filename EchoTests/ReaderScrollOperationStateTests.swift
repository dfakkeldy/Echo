// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct ReaderScrollOperationStateTests {
    @Test func queuedReturnIsDroppedWhenDragPrecedesSnapshotCompletion() throws {
        var state = ReaderScrollOperationState()
        let enqueuedRequest = state.enqueue(
            intent: .returnToCurrent,
            blockID: "current",
            wordIndex: 2,
            scrollGeneration: 7
        )
        let request = try #require(enqueuedRequest)
        #expect(request.scrollGeneration == 7)
        #expect(request.snapshotGeneration == 0)
        let snapshot = state.beginSnapshot()

        state.invalidateForUserDrag()
        state.completeSnapshot(snapshot)

        let readyRequestAfterDrag = state.takeReadyRequest()
        #expect(readyRequestAfterDrag == nil)
        #expect(state.mayExecute(request, currentScrollGeneration: 8) == false)
    }

    @Test func newerSnapshotRebindsDrainedOperationBeforeItCanExecute() throws {
        var state = ReaderScrollOperationState()
        let enqueuedOriginal = state.enqueue(
            intent: .followPlayback,
            blockID: "current",
            wordIndex: 2,
            scrollGeneration: 4
        )
        let original = try #require(enqueuedOriginal)
        let readyRequest = state.takeReadyRequest()
        let drained = try #require(readyRequest)
        #expect(drained == original)
        #expect(state.mayExecute(drained, currentScrollGeneration: 4))

        let snapshot = state.beginSnapshot()
        #expect(state.mayExecute(drained, currentScrollGeneration: 4) == false)

        state.completeSnapshot(snapshot)
        let reboundRequest = state.takeReadyRequest()
        let rebound = try #require(reboundRequest)
        #expect(rebound.operationToken == original.operationToken)
        #expect(rebound.snapshotGeneration == snapshot)
        #expect(rebound != original)
        #expect(state.mayExecute(rebound, currentScrollGeneration: 4))
    }

    @Test func supersedingReturnInvalidatesAnAlreadyDrainedFollow() throws {
        var state = ReaderScrollOperationState()
        let enqueuedFollow = state.enqueue(
            intent: .followPlayback,
            blockID: "older",
            wordIndex: nil,
            scrollGeneration: 2
        )
        let follow = try #require(enqueuedFollow)
        let readyFollow = state.takeReadyRequest()
        _ = try #require(readyFollow)
        let enqueuedReturn = state.enqueue(
            intent: .returnToCurrent,
            blockID: "current",
            wordIndex: 3,
            scrollGeneration: 2
        )
        let `return` = try #require(enqueuedReturn)

        #expect(`return`.operationToken == follow.operationToken &+ 1)
        #expect(state.mayExecute(follow, currentScrollGeneration: 2) == false)
        let readyReturn = state.takeReadyRequest()
        #expect(readyReturn == `return`)
    }

    @Test func returnKeepsPriorityOverPlaybackFollowAndRequiresExactGenerations() throws {
        var state = ReaderScrollOperationState()
        let enqueuedReturn = state.enqueue(
            intent: .returnToCurrent,
            blockID: "current",
            wordIndex: 1,
            scrollGeneration: 9
        )
        let `return` = try #require(enqueuedReturn)

        let enqueuedFollow = state.enqueue(
            intent: .followPlayback,
            blockID: "later",
            wordIndex: 2,
            scrollGeneration: 9
        )
        #expect(enqueuedFollow == nil)
        let readyRequest = state.takeReadyRequest()
        let drained = try #require(readyRequest)
        #expect(drained == `return`)
        #expect(state.mayExecute(drained, currentScrollGeneration: 8) == false)
        #expect(state.mayExecute(drained, currentScrollGeneration: 9))
    }
}
