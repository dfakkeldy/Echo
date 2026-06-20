// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct FSRSMigrationTests {
    @Test func seed_intervalBecomesStability_defaultEaseIsNeutralDifficulty() {
        let s = FSRSMigration.seed(intervalDays: 14, easeFactor: 2.5)
        #expect(s.stability == 14)
        #expect(s.difficulty == 5)
    }

    @Test func seed_lowEase_pushesDifficultyHigh_clampedToTen() {
        let s = FSRSMigration.seed(intervalDays: 1, easeFactor: 1.3)
        // 5 - (1.3 - 2.5) * 5 = 5 + 6 = 11 -> clamped to 10
        #expect(s.difficulty == 10)
        #expect(s.stability == 1)
    }

    @Test func seed_zeroInterval_isFlooredStability() {
        let s = FSRSMigration.seed(intervalDays: 0, easeFactor: 2.5)
        #expect(s.stability == 0.1)
    }
}
