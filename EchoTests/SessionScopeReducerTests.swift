// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import Testing

@testable import Echo

@Suite struct SessionScopeReducerTests {
    private let times: [String: TimeInterval] = [
        "b1": 0,
        "b2": 30,
        "b3": 90,
        "b4": 150,
    ]

    @Test func wholeBookReturnsNilFilter() {
        #expect(
            SessionScopeReducer.blockIDsInScope(
                audioStartTimeByBlockID: times, scope: .wholeBook
            ) == nil)
    }

    @Test func sessionWindowSelectsInclusiveRange() {
        let result = SessionScopeReducer.blockIDsInScope(
            audioStartTimeByBlockID: times, scope: .session(start: 30, end: 90)
        )
        #expect(result == ["b2", "b3"])
    }

    @Test func reversedWindowIsNormalized() {
        let result = SessionScopeReducer.blockIDsInScope(
            audioStartTimeByBlockID: times, scope: .session(start: 90, end: 30)
        )
        #expect(result == ["b2", "b3"])
    }

    @Test func emptyWindowReturnsEmptySet() {
        let result = SessionScopeReducer.blockIDsInScope(
            audioStartTimeByBlockID: times, scope: .session(start: 1000, end: 2000)
        )
        #expect(result == [])
    }
}
