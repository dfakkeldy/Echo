// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct ReaderScrollOperationStateTests {
    @Test func queuedReturnIsDroppedWhenDragPrecedesSnapshotCompletion() throws {
        var state = ReaderScrollOperationState()
        let request = try #require(
            state.enqueue(
                intent: .returnToCurrent,
                blockID: "current",
                wordIndex: 2,
                scrollGeneration: 7
            )
        )
        #expect(request.scrollGeneration == 7)
        #expect(request.snapshotGeneration == 0)
        let snapshot = state.beginSnapshot()

        state.invalidateForUserDrag()
        state.completeSnapshot(snapshot)

        #expect(state.takeReadyRequest() == nil)
        #expect(state.mayExecute(request, currentScrollGeneration: 8) == false)
    }

    @Test func newerSnapshotRebindsDrainedOperationBeforeItCanExecute() throws {
        var state = ReaderScrollOperationState()
        let original = try #require(
            state.enqueue(
                intent: .followPlayback,
                blockID: "current",
                wordIndex: 2,
                scrollGeneration: 4
            )
        )
        let drained = try #require(state.takeReadyRequest())
        #expect(drained == original)
        #expect(state.mayExecute(drained, currentScrollGeneration: 4))

        let snapshot = state.beginSnapshot()
        #expect(state.mayExecute(drained, currentScrollGeneration: 4) == false)

        state.completeSnapshot(snapshot)
        let rebound = try #require(state.takeReadyRequest())
        #expect(rebound.operationToken == original.operationToken)
        #expect(rebound.snapshotGeneration == snapshot)
        #expect(rebound != original)
        #expect(state.mayExecute(rebound, currentScrollGeneration: 4))
    }

    @Test func supersedingReturnInvalidatesAnAlreadyDrainedFollow() throws {
        var state = ReaderScrollOperationState()
        let follow = try #require(
            state.enqueue(
                intent: .followPlayback,
                blockID: "older",
                wordIndex: nil,
                scrollGeneration: 2
            )
        )
        _ = try #require(state.takeReadyRequest())
        let `return` = try #require(
            state.enqueue(
                intent: .returnToCurrent,
                blockID: "current",
                wordIndex: 3,
                scrollGeneration: 2
            )
        )

        #expect(`return`.operationToken == follow.operationToken &+ 1)
        #expect(state.mayExecute(follow, currentScrollGeneration: 2) == false)
        #expect(state.takeReadyRequest() == `return`)
    }

    @Test func returnKeepsPriorityOverPlaybackFollowAndRequiresExactGenerations() throws {
        var state = ReaderScrollOperationState()
        let `return` = try #require(
            state.enqueue(
                intent: .returnToCurrent,
                blockID: "current",
                wordIndex: 1,
                scrollGeneration: 9
            )
        )

        #expect(
            state.enqueue(
                intent: .followPlayback,
                blockID: "later",
                wordIndex: 2,
                scrollGeneration: 9
            ) == nil
        )
        let drained = try #require(state.takeReadyRequest())
        #expect(drained == `return`)
        #expect(state.mayExecute(drained, currentScrollGeneration: 8) == false)
        #expect(state.mayExecute(drained, currentScrollGeneration: 9))
    }
}
