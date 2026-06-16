// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Echo

@Suite struct StatsAggregatorTests {

    // MARK: - Bucketing

    @Test func bucketDayGroupsByCalendarDay() {
        let cal = Calendar(identifier: .gregorian)
        var dc = DateComponents(timeZone: TimeZone(secondsFromGMT: 0))
        dc.year = 2026; dc.month = 6; dc.day = 10; dc.hour = 10
        let day1 = cal.date(from: dc)!
        dc.day = 11
        let day2 = cal.date(from: dc)!
        dc.day = 12
        let day3 = cal.date(from: dc)!

        let segments = [
            makeSegment(audiobookID: "b1", startedAt: day1, duration: 120),
            makeSegment(audiobookID: "b1", startedAt: day1.addingTimeInterval(3600), duration: 60),
            makeSegment(audiobookID: "b2", startedAt: day2, duration: 300),
            makeSegment(audiobookID: "b1", startedAt: day3, duration: 45),
        ]

        let buckets = StatsAggregator.bucket(segments: segments, by: .day, calendar: cal, now: day3)

        #expect(buckets.count == 3)
        #expect(buckets[0].totalPlaybackDuration == 180)
        #expect(buckets[1].totalPlaybackDuration == 300)
        #expect(buckets[2].totalPlaybackDuration == 45)
    }

    @Test func bucketAllAggregatesEverything() {
        let now = Date()
        let segments = [
            makeSegment(audiobookID: "b1", startedAt: now, duration: 100),
            makeSegment(audiobookID: "b1", startedAt: now.addingTimeInterval(7200), duration: 200),
        ]

        let buckets = StatsAggregator.bucket(segments: segments, by: .all, now: now)

        #expect(buckets.count == 1)
        #expect(buckets[0].totalPlaybackDuration == 300)
        #expect(buckets[0].segmentCount == 2)
    }

    @Test func bucketEmptyReturnsEmpty() {
        let buckets = StatsAggregator.bucket(segments: [], by: .day)
        #expect(buckets.isEmpty)
    }

    @Test func bucketWeekGroupsByWeekOfYear() {
        let cal = Calendar(identifier: .gregorian)
        var dc = DateComponents(timeZone: TimeZone(secondsFromGMT: 0))
        dc.year = 2026; dc.month = 6; dc.day = 1 // Monday
        let mon = cal.date(from: dc)!
        dc.day = 10 // Wednesday next week
        let wed = cal.date(from: dc)!

        let segments = [
            makeSegment(audiobookID: "b1", startedAt: mon, duration: 100),
            makeSegment(audiobookID: "b1", startedAt: wed, duration: 200),
        ]

        let buckets = StatsAggregator.bucket(segments: segments, by: .week, calendar: cal, now: wed)

        #expect(buckets.count == 2)
    }

    @Test func adjustedDurationDividesBySpeed() {
        let now = Date()
        let seg = ListeningSegment(
            audiobookID: "b1", trackID: nil,
            startedAt: now, endedAt: now.addingTimeInterval(600),
            startPosition: 0, endPosition: 600, speed: 2.0, source: nil
        )
        #expect(seg.adjustedDuration == 300)
        #expect(seg.playbackDuration == 600)
    }

    @Test func adjustedDurationHandlesZeroSpeed() {
        let now = Date()
        let seg = ListeningSegment(
            audiobookID: "b1", trackID: nil,
            startedAt: now, endedAt: now.addingTimeInterval(100),
            startPosition: 0, endPosition: 100, speed: 0, source: nil
        )
        // When speed is 0, adjustedDuration falls back to playbackDuration
        #expect(seg.adjustedDuration == 100)
    }

    // MARK: - Streaks

    @Test func streakConsecutiveDays() {
        let cal = Calendar(identifier: .gregorian)
        var dc = DateComponents(timeZone: TimeZone(secondsFromGMT: 0))
        dc.year = 2026; dc.month = 6; dc.day = 12; dc.hour = 12
        let today = cal.date(from: dc)!
        dc.day = 11
        let yesterday = cal.date(from: dc)!
        dc.day = 10
        let twoDaysAgo = cal.date(from: dc)!
        dc.day = 8
        let fourDaysAgo = cal.date(from: dc)!

        let activeDays: Set<Date> = [today, yesterday, twoDaysAgo, fourDaysAgo]
        let streak = StatsAggregator.streak(activeDays: activeDays, calendar: cal, now: today)

        #expect(streak.currentStreakDays == 3)
        #expect(streak.longestStreakDays == 3)
    }

    @Test func streakGracePeriodYesterdayCounts() {
        let cal = Calendar(identifier: .gregorian)
        var dc = DateComponents(timeZone: TimeZone(secondsFromGMT: 0))
        dc.year = 2026; dc.month = 6; dc.day = 12; dc.hour = 12
        let today = cal.date(from: dc)!
        dc.day = 11
        let yesterday = cal.date(from: dc)!

        let activeDays: Set<Date> = [yesterday]
        let streak = StatsAggregator.streak(activeDays: activeDays, calendar: cal, now: today)

        #expect(streak.currentStreakDays == 1)
    }

    @Test func streakEmpty() {
        let streak = StatsAggregator.streak(activeDays: [], calendar: .current, now: Date())
        #expect(streak.currentStreakDays == 0)
        #expect(streak.longestStreakDays == 0)
    }

    @Test func streakLongestNotCurrent() {
        let cal = Calendar(identifier: .gregorian)
        var dc = DateComponents(timeZone: TimeZone(secondsFromGMT: 0))
        dc.year = 2026; dc.month = 6; dc.day = 12; dc.hour = 12
        let today = cal.date(from: dc)!
        dc.day = 11
        let yesterday = cal.date(from: dc)!
        dc.day = 3
        let day3 = cal.date(from: dc)!
        dc.day = 2
        let day2 = cal.date(from: dc)!
        dc.day = 1
        let day1 = cal.date(from: dc)!

        let activeDays: Set<Date> = [today, yesterday, day1, day2, day3]
        let streak = StatsAggregator.streak(activeDays: activeDays, calendar: cal, now: today)

        #expect(streak.currentStreakDays == 2)
        #expect(streak.longestStreakDays == 3)
    }

    @Test func streakTodayOnly() {
        let cal = Calendar(identifier: .gregorian)
        var dc = DateComponents(timeZone: TimeZone(secondsFromGMT: 0))
        dc.year = 2026; dc.month = 6; dc.day = 12; dc.hour = 12
        let today = cal.date(from: dc)!

        let activeDays: Set<Date> = [today]
        let streak = StatsAggregator.streak(activeDays: activeDays, calendar: cal, now: today)

        #expect(streak.currentStreakDays == 1)
        #expect(streak.longestStreakDays == 1)
    }

    // MARK: - Interval Merging

    @Test func mergeIntervalsOverlapping() {
        let intervals: [ClosedRange<TimeInterval>] = [0...10, 5...15, 20...30]
        let merged = StatsAggregator.mergeIntervals(intervals)
        #expect(merged.count == 2)
        #expect(merged[0] == 0...15)
        #expect(merged[1] == 20...30)
    }

    @Test func mergeIntervalsAdjacentWithTolerance() {
        let intervals: [ClosedRange<TimeInterval>] = [0...10, 12...20]
        let merged = StatsAggregator.mergeIntervals(intervals, gapTolerance: 2)
        #expect(merged.count == 1)
        #expect(merged[0] == 0...20)
    }

    @Test func mergeIntervalsAdjacentNoTolerance() {
        let intervals: [ClosedRange<TimeInterval>] = [0...10, 12...20]
        let merged = StatsAggregator.mergeIntervals(intervals, gapTolerance: 0)
        #expect(merged.count == 2)
    }

    @Test func mergeIntervalsEmpty() {
        #expect(StatsAggregator.mergeIntervals([]).isEmpty)
    }

    @Test func mergeIntervalsSingle() {
        let merged = StatsAggregator.mergeIntervals([0...10])
        #expect(merged.count == 1)
        #expect(merged[0] == 0...10)
    }

    @Test func mergeIntervalsNested() {
        let merged = StatsAggregator.mergeIntervals([0...100, 20...50, 80...200])
        #expect(merged.count == 1)
        #expect(merged[0] == 0...200)
    }

    @Test func mergeIntervalsTouchingMerge() {
        let intervals: [ClosedRange<TimeInterval>] = [0...10, 10...20]
        let merged = StatsAggregator.mergeIntervals(intervals, gapTolerance: 0)
        // When upperBound == lowerBound, interval.lowerBound (10) <= last.upperBound (10) + 0 → true
        #expect(merged.count == 1)
        #expect(merged[0] == 0...20)
    }

    // MARK: - Chapter Coverage

    @Test func chapterCoverageFull() {
        let (frac, passes) = StatsAggregator.chapterCoverage(
            chapterStart: 0, chapterEnd: 1000,
            listenedIntervals: [0...1000]
        )
        #expect(frac == 1.0)
        #expect(passes == 1)
    }

    @Test func chapterCoverageHalf() {
        let (frac, passes) = StatsAggregator.chapterCoverage(
            chapterStart: 0, chapterEnd: 1000,
            listenedIntervals: [0...500]
        )
        #expect(frac == 0.5)
        #expect(passes == 1)
    }

    @Test func chapterCoverageMultiplePasses() {
        let (frac, passes) = StatsAggregator.chapterCoverage(
            chapterStart: 0, chapterEnd: 1000,
            listenedIntervals: [0...200, 800...1000]
        )
        #expect(frac == 0.4)
        #expect(passes == 2)
    }

    @Test func chapterCoverageMicroPassNotCounted() {
        let (frac, passes) = StatsAggregator.chapterCoverage(
            chapterStart: 0, chapterEnd: 1000,
            listenedIntervals: [0...10]
        )
        #expect(frac == 0.01)
        #expect(passes == 0)
    }

    @Test func chapterCoverageEmptyChapter() {
        let (frac, passes) = StatsAggregator.chapterCoverage(
            chapterStart: 100, chapterEnd: 100,
            listenedIntervals: [0...200]
        )
        #expect(frac == 0)
        #expect(passes == 0)
    }

    @Test func chaptersCoverageArray() {
        let chapters = [
            (id: 1, title: "Ch 1", startSeconds: 0.0, endSeconds: 1000.0),
            (id: 2, title: "Ch 2", startSeconds: 1000.0, endSeconds: 2000.0),
        ]
        let intervals: [ClosedRange<TimeInterval>] = [0...600, 1200...1800]
        let result = StatsAggregator.chaptersCoverage(chapters: chapters, listenedIntervals: intervals)
        #expect(result.count == 2)
        #expect(result[0].coveredFraction == 0.6)
        #expect(result[1].coveredFraction == 0.6)
    }

    // MARK: - Time-of-Day Histogram

    @Test func timeOfDayHistogramSingleHour() {
        let cal = Calendar.current
        let now = Date()
        var dc = cal.dateComponents([.year, .month, .day], from: now)
        dc.hour = 9; dc.minute = 0
        let start = cal.date(from: dc)!
        let end = cal.date(byAdding: .minute, value: 30, to: start)!

        let segments = [
            ListeningSegment(
                audiobookID: "b1", trackID: nil,
                startedAt: start, endedAt: end,
                startPosition: 0, endPosition: 1800, speed: 1.0, source: nil
            )
        ]

        let hist = StatsAggregator.timeOfDayHistogram(segments: segments, calendar: cal)
        #expect(hist.count == 24)
        #expect(hist[9].totalAdjustedDuration == 1800)
        #expect(hist[0].totalAdjustedDuration == 0)
        #expect(hist[23].totalAdjustedDuration == 0)
    }

    @Test func timeOfDayHistogramMultiHourSplitsProportionally() {
        let cal = Calendar.current
        let now = Date()
        var dc = cal.dateComponents([.year, .month, .day], from: now)
        dc.hour = 9; dc.minute = 30
        let start = cal.date(from: dc)!
        let end = cal.date(byAdding: .minute, value: 60, to: start)! // 9:30–10:30

        let segments = [
            ListeningSegment(
                audiobookID: "b1", trackID: nil,
                startedAt: start, endedAt: end,
                startPosition: 0, endPosition: 3600, speed: 1.0, source: nil
            )
        ]

        let hist = StatsAggregator.timeOfDayHistogram(segments: segments, calendar: cal)
        // Spans hours 9 and 10 (2 hours), each gets 1800
        #expect(hist[9].totalAdjustedDuration == 1800)
        #expect(hist[10].totalAdjustedDuration == 1800)
    }

    // MARK: - Speed Trend

    @Test func speedTrendWeightedByDuration() {
        let cal = Calendar.current
        let now = Date()
        let day = cal.startOfDay(for: now)

        let segments = [
            makeSegmentWithSpeed(audiobookID: "b1", startedAt: day, duration: 600, speed: 1.5),
            makeSegmentWithSpeed(audiobookID: "b1", startedAt: day.addingTimeInterval(3600), duration: 300, speed: 2.0),
        ]

        let trend = StatsAggregator.speedTrend(segments: segments, calendar: cal)
        #expect(trend.count == 1)
        let expected = (600 * 1.5 + 300 * 2.0) / (600 + 300) // 1500/900 = 1.666...
        #expect(abs(trend[0].averageSpeed - expected) < 0.01)
    }

    @Test func speedTrendEmpty() {
        let trend = StatsAggregator.speedTrend(segments: [])
        #expect(trend.isEmpty)
    }

    // MARK: - Session Length Distribution

    @Test func sessionLengthDistributionBuckets() {
        let now = Date()
        let segments = [
            makeSegment(audiobookID: "b1", startedAt: now, duration: 120),
            makeSegment(audiobookID: "b1", startedAt: now, duration: 600),
            makeSegment(audiobookID: "b1", startedAt: now, duration: 1200),
            makeSegment(audiobookID: "b1", startedAt: now, duration: 5000),
        ]

        let dist = StatsAggregator.sessionLengthDistribution(segments: segments)
        #expect(dist.count == 5)
        #expect(dist[0].count == 1) // 0-5m
        #expect(dist[1].count == 1) // 5-15m
        #expect(dist[2].count == 1) // 15-30m
        #expect(dist[3].count == 0) // 30-60m
        #expect(dist[4].count == 1) // 60m+
    }

    @Test func sessionLengthDistributionEmpty() {
        let dist = StatsAggregator.sessionLengthDistribution(segments: [])
        #expect(dist.allSatisfy { $0.count == 0 })
    }

    // MARK: - Retention Curve

    @Test func retentionCurveGroupsByInterval() {
        let reviews: [(intervalDays: Int, grade: Int)] = [
            (1, 4), (1, 3), (1, 2),
            (7, 4), (7, 4),
            (30, 1),
        ]

        let curve = StatsAggregator.retentionCurve(reviews: reviews)
        #expect(curve.count == 3)

        let at1 = curve.first { $0.intervalDays == 1 }!
        #expect(abs(at1.retentionRate - 2.0/3.0) < 0.01)

        let at7 = curve.first { $0.intervalDays == 7 }!
        #expect(at7.retentionRate == 1.0)

        let at30 = curve.first { $0.intervalDays == 30 }!
        #expect(at30.retentionRate == 0.0)
    }

    @Test func retentionCurveEmpty() {
        #expect(StatsAggregator.retentionCurve(reviews: []).isEmpty)
    }

    @Test func retentionCurveAllGrades() {
        // Grade 3 is the threshold — at or above is "remembered"
        let reviews: [(intervalDays: Int, grade: Int)] = [
            (1, 0), (1, 1), (1, 2), // not remembered
            (1, 3), (1, 4), (1, 5), // remembered
        ]
        let curve = StatsAggregator.retentionCurve(reviews: reviews)
        #expect(curve.count == 1)
        #expect(curve[0].retentionRate == 0.5)
    }

    // MARK: - Due Forecast

    @Test func dueForecastProjectsCorrectly() {
        let cal = Calendar(identifier: .gregorian)
        var dc = DateComponents(timeZone: TimeZone(secondsFromGMT: 0))
        dc.year = 2026; dc.month = 6; dc.day = 12; dc.hour = 12
        let now = cal.date(from: dc)!

        let cards: [(nextReviewDate: Date, isEnabled: Bool)] = [
            (cal.date(byAdding: .day, value: 0, to: now)!, true),
            (cal.date(byAdding: .day, value: 1, to: now)!, true),
            (cal.date(byAdding: .day, value: 5, to: now)!, true),
            (cal.date(byAdding: .day, value: 0, to: now)!, false),
        ]

        let forecast = StatsAggregator.dueForecast(cards: cards, days: 7, calendar: cal, now: now)
        #expect(forecast.count == 7)
        #expect(forecast[0].dueCount == 1) // day 0: only the enabled due-today card
        #expect(forecast[1].dueCount == 2) // day 1: today's + tomorrow's
        #expect(forecast[5].dueCount == 3) // day 5: all 3 enabled cards
    }

    @Test func dueForecastEmpty() {
        let forecast = StatsAggregator.dueForecast(cards: [], days: 7)
        #expect(forecast.allSatisfy { $0.dueCount == 0 })
    }

    // MARK: - Grade Distribution

    @Test func gradeDistributionCountsAllGrades() {
        let grades = [0, 1, 3, 3, 4, 4, 4, 5]
        let dist = StatsAggregator.gradeDistribution(reviews: grades)
        #expect(dist.count == 6)
        #expect(dist[0].count == 1)
        #expect(dist[1].count == 1)
        #expect(dist[2].count == 0)
        #expect(dist[3].count == 2)
        #expect(dist[4].count == 3)
        #expect(dist[5].count == 1)
    }

    @Test func gradeDistributionEmpty() {
        let dist = StatsAggregator.gradeDistribution(reviews: [])
        #expect(dist.allSatisfy { $0.count == 0 })
    }

    // MARK: - Daily Totals

    @Test func dailyTotalsGroupsByDay() {
        let cal = Calendar(identifier: .gregorian)
        var dc = DateComponents(timeZone: TimeZone(secondsFromGMT: 0))
        dc.year = 2026; dc.month = 6; dc.day = 10; dc.hour = 10
        let day1 = cal.date(from: dc)!
        dc.day = 11; dc.hour = 14
        let day2 = cal.date(from: dc)!

        let segments = [
            makeSegment(audiobookID: "b1", startedAt: day1, duration: 100),
            makeSegment(audiobookID: "b1", startedAt: day1.addingTimeInterval(7200), duration: 200),
            makeSegment(audiobookID: "b1", startedAt: day2, duration: 50),
        ]

        let totals = StatsAggregator.dailyTotals(segments: segments, calendar: cal)
        #expect(totals.count == 2)
        #expect(totals[0].totalPlaybackDuration == 300)
        #expect(totals[0].segmentCount == 2)
        #expect(totals[1].totalPlaybackDuration == 50)
        #expect(totals[1].segmentCount == 1)
    }

    // MARK: - Planner Adherence

    @Test func plannerAdherenceMeasuresOverlap() {
        let cal = Calendar.current
        let now = Date()
        let planStart = cal.startOfDay(for: now)
        let planEnd = cal.date(byAdding: .hour, value: 1, to: planStart)!

        let plans = [(startTime: planStart, endTime: planEnd, isCompleted: true)]
        let listening = [(startedAt: planStart.addingTimeInterval(300), playbackDuration: 600.0)]

        let adherence = StatsAggregator.plannerAdherence(
            plannedSessions: plans,
            listeningSegments: listening
        )

        #expect(adherence.totalPlannedSessions == 1)
        #expect(adherence.completedSessions == 1)
        #expect(adherence.completionRate == 1.0)
        #expect(adherence.actualListenedDuringPlanned == 600)
    }

    @Test func plannerAdherenceEmpty() {
        let adherence = StatsAggregator.plannerAdherence(
            plannedSessions: [],
            listeningSegments: []
        )
        #expect(adherence.completionRate == 0)
        #expect(adherence.totalPlannedSessions == 0)
    }

    @Test func plannerAdherencePartialCompletion() {
        let now = Date()
        let plans = [
            (startTime: now.addingTimeInterval(-7200), endTime: now.addingTimeInterval(-3600), isCompleted: true),
            (startTime: now.addingTimeInterval(-3600), endTime: now, isCompleted: false),
        ]
        let listening: [(startedAt: Date, playbackDuration: TimeInterval)] = []

        let adherence = StatsAggregator.plannerAdherence(
            plannedSessions: plans,
            listeningSegments: listening
        )
        #expect(adherence.completionRate == 0.5)
        #expect(adherence.completedSessions == 1)
        #expect(adherence.totalPlannedSessions == 2)
    }

    // MARK: - Helpers

    private func makeSegment(
        audiobookID: String,
        startedAt: Date,
        duration: TimeInterval
    ) -> ListeningSegment {
        ListeningSegment(
            audiobookID: audiobookID, trackID: nil,
            startedAt: startedAt, endedAt: startedAt.addingTimeInterval(duration),
            startPosition: 0, endPosition: duration, speed: 1.0, source: nil
        )
    }

    private func makeSegmentWithSpeed(
        audiobookID: String,
        startedAt: Date,
        duration: TimeInterval,
        speed: Double
    ) -> ListeningSegment {
        ListeningSegment(
            audiobookID: audiobookID, trackID: nil,
            startedAt: startedAt, endedAt: startedAt.addingTimeInterval(duration),
            startPosition: 0, endPosition: duration, speed: speed, source: nil
        )
    }
}
