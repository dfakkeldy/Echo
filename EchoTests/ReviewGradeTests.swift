// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct ReviewGradeTests {
    @Test func rawValuesMatchFSRSScale() {
        #expect(ReviewGrade.again.rawValue == 1)
        #expect(ReviewGrade.hard.rawValue == 2)
        #expect(ReviewGrade.good.rawValue == 3)
        #expect(ReviewGrade.easy.rawValue == 4)
    }

    @Test func allCasesOrderedAgainToEasy() {
        #expect(ReviewGrade.allCases == [.again, .hard, .good, .easy])
        #expect(ReviewGrade.allCases.map(\.label) == ["Again", "Hard", "Good", "Easy"])
    }
}
