// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Echo

struct SchedulingAlgorithmTests {
    /// Fixed clock so all scheduler calls are deterministic.
    private let now = Date(timeIntervalSince1970: 1_750_000_000)

    // ── MARK: SM-2 ──

    @Test func sm2_firstCorrectReview_intervalIsOne() {
        let card = makeCard()
        let scheduler = SM2Scheduler()
        let result = scheduler.review(card: card, grade: 3, now: now)
        #expect(result.intervalDays == 1)
        #expect(result.repetitions == 1)
    }

    @Test func sm2_secondCorrectReview_intervalIsSix() {
        let card = makeCard(repetitions: 1)
        let scheduler = SM2Scheduler()
        let result = scheduler.review(card: card, grade: 4, now: now)
        #expect(result.intervalDays == 6)
        #expect(result.repetitions == 2)
    }

    @Test func sm2_incorrectResetsInterval() {
        let card = makeCard(intervalDays: 30, repetitions: 5, easeFactor: 2.5)
        let scheduler = SM2Scheduler()
        let result = scheduler.review(card: card, grade: 1, now: now)
        #expect(result.intervalDays == 1)
        #expect(result.repetitions == 0)
    }

    @Test func sm2_easeFactorFloor() {
        let card = makeCard(easeFactor: 1.3)
        let scheduler = SM2Scheduler()
        let result = scheduler.review(card: card, grade: 1, now: now)
        #expect(result.easeFactor >= 1.3)
    }

    @Test func sm2_intervalGrowsOverPerfectReviews() {
        var card = makeCard()
        let scheduler = SM2Scheduler()
        var intervals: [Int] = []
        for grade in [3, 4, 4, 4, 4] {
            card = scheduler.review(card: card, grade: grade, now: now)
            intervals.append(card.intervalDays)
        }
        // Canonical SM-2: the first grade-3 review drops EF from 2.5 to 2.36
        // (ΔEF = 0.1 - (5-3)(0.08 + (5-3)·0.02) = -0.14); grade-4 reviews leave EF
        // unchanged, so from review 3 intervals grow by 2.36×:
        // 6×2.36=14.16→14, 14×2.36=33.04→33, 33×2.36=77.88→77.
        #expect(intervals == [1, 6, 14, 33, 77])
    }

    // ── MARK: FSRS ──

    @Test func fsrs_firstGoodReview_setsStabilityAndDifficulty() {
        let card = makeCard()
        let scheduler = FSRSScheduler()
        let result = scheduler.review(card: card, grade: 3, now: now)
        // First-review stability is S_0(Good) = w[2] = 2.4.
        #expect(result.stability != nil)
        #expect(result.difficulty != nil)
        #expect(result.intervalDays >= 1)
    }

    @Test func fsrs_firstFail_lowStability() {
        let card = makeCard()
        let scheduler = FSRSScheduler()
        let result = scheduler.review(card: card, grade: 1, now: now)
        // First-review stability is the initial DSR S_0(G) = w[G-1]; for a fail
        // (Again, G=1) that is w[0] = 0.4 — the lowest of the four initial values.
        #expect(result.stability ?? 0 == 0.4)
        #expect(result.intervalDays >= 1)
    }

    @Test func fsrs_stabilityGrowsWithGoodGrades() {
        var card = makeCard()
        let scheduler = FSRSScheduler()
        var reviewDate = now
        let stabilities: [Double] = (1...5).map { _ in
            card = scheduler.review(card: card, grade: 4, now: reviewDate)
            // Review on schedule: advance the clock by the new interval so the
            // next review happens after a real delay (retrievability < 1).
            // Reviewing repeatedly at the same instant correctly yields no
            // stability gain in FSRS, so the clock must move.
            reviewDate = reviewDate.addingTimeInterval(Double(card.intervalDays) * 86_400)
            return card.stability ?? 0
        }
        // Each successive on-schedule review should increase stability.
        for i in 1..<stabilities.count {
            #expect(stabilities[i] > stabilities[i - 1])
        }
    }

    @Test func fsrs_deterministicWithFixedClock() {
        let scheduler = FSRSScheduler()
        let card = makeCard()
        let a = scheduler.review(card: card, grade: 3, now: now)
        let b = scheduler.review(card: card, grade: 3, now: now)
        #expect(a.stability == b.stability)
        #expect(a.difficulty == b.difficulty)
        #expect(a.intervalDays == b.intervalDays)
    }

    @Test func fsrs_difficultyBoundedOneToTen() {
        let scheduler = FSRSScheduler()
        // Very low grade should push difficulty high
        let lowGrade = scheduler.review(card: makeCard(difficulty: 1.0), grade: 1, now: now)
        #expect((lowGrade.difficulty ?? 0) >= 1.0)
        #expect((lowGrade.difficulty ?? 10) <= 10.0)
    }

    @Test func fsrsPersistsClampedLowGrade() {
        let scheduler = FSRSScheduler()
        let result = scheduler.review(card: makeCard(), grade: 0, now: now)

        #expect(result.lastGrade == ReviewGrade.again.rawValue)
    }

    @Test func fsrsPersistsClampedHighGrade() {
        let scheduler = FSRSScheduler()
        let result = scheduler.review(card: makeCard(), grade: 5, now: now)

        #expect(result.lastGrade == ReviewGrade.easy.rawValue)
    }

    // ── Helpers ──

    private func makeCard(
        intervalDays: Int = 0,
        repetitions: Int = 0,
        easeFactor: Double = 2.5,
        stability: Double? = nil,
        difficulty: Double? = nil
    ) -> Flashcard {
        Flashcard(
            id: "test-\(UUID().uuidString)",
            audiobookID: "test-book",
            frontText: "Front",
            backText: "Back",
            mediaTimestamp: 0,
            endTimestamp: nil,
            triggerTiming: .manualOnly,
            nextReviewDate: nil,
            intervalDays: intervalDays,
            easeFactor: easeFactor,
            repetitions: repetitions,
            lastReviewedAt: nil,
            lastGrade: nil,
            isEnabled: true,
            deckID: nil,
            tags: nil,
            mediaJSON: nil,
            sourceBlockID: nil,
            playlistPosition: nil,
            createdAt: nil,
            modifiedAt: nil,
            stability: stability,
            difficulty: difficulty,
            cardType: nil,
            clozeIndex: nil
        )
    }
}
