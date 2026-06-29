// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Pure, synchronous aggregation functions. No database access.
/// Every function is deterministic given the same inputs and calendar.
///
/// The four review/forecast functions (`retentionCurve`, `dueForecast`,
/// `gradeDistribution`, `plannerAdherence`) are individually marked
/// `nonisolated` so they can be invoked from the `@Sendable` GRDB reader
/// closures in `StatsRepository` (audit §3.3). They are fully self-contained —
/// only their value-type parameters and Foundation are used. The remaining
/// functions reference main-actor helpers (`Calendar.startOfPeriod`,
/// `ListeningSegment.adjustedDuration`) and are only ever called from
/// main-actor contexts, so they stay on the default (main-actor) isolation.
enum StatsAggregator {

    // MARK: - Bucketing

    /// Groups listening segments into calendar buckets.
    static func bucket(
        segments: [ListeningSegment],
        by bucket: StatsBucket,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> [BucketTotal] {
        guard !segments.isEmpty else { return [] }

        switch bucket {
        case .all:
            let total = aggregate(segments: segments)
            return [BucketTotal(
                id: "all",
                startDate: segments.map(\.startedAt).min() ?? now,
                endDate: now,
                totalPlaybackDuration: total.playback,
                totalAdjustedDuration: total.adjusted,
                segmentCount: segments.count
            )]

        case .day, .week, .month, .year:
            var groups: [Date: [ListeningSegment]] = [:]
            for segment in segments {
                let key = calendar.startOfPeriod(bucket, for: segment.startedAt)
                groups[key, default: []].append(segment)
            }
            return groups.map { key, segs in
                let t = aggregate(segments: segs)
                let end = calendar.endOfPeriod(bucket, for: key)
                return BucketTotal(
                    id: ISO8601DateFormatter().string(from: key),
                    startDate: key,
                    endDate: end,
                    totalPlaybackDuration: t.playback,
                    totalAdjustedDuration: t.adjusted,
                    segmentCount: segs.count
                )
            }.sorted { $0.startDate < $1.startDate }
        }
    }

    // MARK: - Daily Totals

    static func dailyTotals(
        segments: [ListeningSegment],
        calendar: Calendar = .current
    ) -> [DailyTotal] {
        var groups: [Date: [ListeningSegment]] = [:]
        for segment in segments {
            let day = calendar.startOfDay(for: segment.startedAt)
            groups[day, default: []].append(segment)
        }
        return groups.map { day, segs in
            let t = aggregate(segments: segs)
            return DailyTotal(
                date: day,
                totalPlaybackDuration: t.playback,
                totalAdjustedDuration: t.adjusted,
                segmentCount: segs.count
            )
        }.sorted { $0.date < $1.date }
    }

    // MARK: - Streaks

    /// Computes current and longest listening streaks from a set of active calendar days.
    /// Today and yesterday both anchor the current streak (grace day).
    static func streak(
        activeDays: Set<Date>,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> StreakInfo {
        guard !activeDays.isEmpty else {
            return StreakInfo(
                currentStreakDays: 0, longestStreakDays: 0,
                currentStreakStart: nil, longestStreakStart: nil, longestStreakEnd: nil
            )
        }

        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today)!

        let days = Set(activeDays.map { calendar.startOfDay(for: $0) })

        // Current: walk backward from yesterday (grace day) until a gap
        var currentStreak = 0
        var currentStart: Date?
        var cursor = yesterday
        while days.contains(cursor) {
            currentStreak += 1
            currentStart = cursor
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        if days.contains(today) {
            if currentStreak == 0 { currentStart = today }
            currentStreak += 1
            if currentStart == nil { currentStart = today }
        }

        // Longest
        let sorted = days.sorted()
        var longestStreak = 0
        var longestStart: Date?
        var longestEnd: Date?
        var runStart = sorted.first!
        var runLength = 1

        for i in 1..<sorted.count {
            let prev = sorted[i - 1]
            let curr = sorted[i]
            if let diff = calendar.dateComponents([.day], from: prev, to: curr).day, diff == 1 {
                runLength += 1
            } else {
                if runLength > longestStreak {
                    longestStreak = runLength
                    longestStart = runStart
                    longestEnd = prev
                }
                runStart = curr
                runLength = 1
            }
        }
        if runLength > longestStreak {
            longestStreak = runLength
            longestStart = runStart
            longestEnd = sorted.last!
        }

        return StreakInfo(
            currentStreakDays: currentStreak,
            longestStreakDays: longestStreak,
            currentStreakStart: currentStart,
            longestStreakStart: longestStart,
            longestStreakEnd: longestEnd
        )
    }

    // MARK: - Interval Merging (Sweep-Line)

    /// Merges overlapping or adjacent position intervals.
    /// Adjacency threshold: intervals that touch or are within `gapTolerance` seconds merge.
    static func mergeIntervals(
        _ intervals: [ClosedRange<TimeInterval>],
        gapTolerance: TimeInterval = 0
    ) -> [ClosedRange<TimeInterval>] {
        guard !intervals.isEmpty else { return [] }
        let sorted = intervals.sorted { $0.lowerBound < $1.lowerBound }
        var merged: [ClosedRange<TimeInterval>] = [sorted[0]]
        for interval in sorted.dropFirst() {
            let last = merged[merged.count - 1]
            if interval.lowerBound <= last.upperBound + gapTolerance {
                let newUpper = max(last.upperBound, interval.upperBound)
                merged[merged.count - 1] = last.lowerBound...newUpper
            } else {
                merged.append(interval)
            }
        }
        return merged
    }

    // MARK: - Chapter Coverage

    /// For one chapter, compute covered fraction and distinct listen passes.
    /// Pass threshold: at least `minPassDuration` seconds of overlap, or 50% of the chapter.
    static func chapterCoverage(
        chapterStart: TimeInterval,
        chapterEnd: TimeInterval,
        listenedIntervals: [ClosedRange<TimeInterval>],
        minPassDuration: TimeInterval = 60
    ) -> (coveredFraction: Double, passCount: Int) {
        let chapterLength = chapterEnd - chapterStart
        guard chapterLength > 0 else { return (0, 0) }

        let merged = mergeIntervals(listenedIntervals)
        var covered: TimeInterval = 0
        var passes = 0
        for interval in merged {
            let overlapStart = max(interval.lowerBound, chapterStart)
            let overlapEnd = min(interval.upperBound, chapterEnd)
            if overlapStart < overlapEnd {
                covered += overlapEnd - overlapStart
                let overlapDuration = overlapEnd - overlapStart
                if overlapDuration >= min(minPassDuration, chapterLength * 0.5) {
                    passes += 1
                }
            }
        }

        return (min(1.0, covered / chapterLength), passes)
    }

    /// Computes ChapterCoverage for an array of chapters given listening intervals.
    static func chaptersCoverage(
        chapters: [(id: Int, title: String, startSeconds: TimeInterval, endSeconds: TimeInterval)],
        listenedIntervals: [ClosedRange<TimeInterval>]
    ) -> [ChapterCoverage] {
        chapters.map { ch in
            let (frac, passes) = chapterCoverage(
                chapterStart: ch.startSeconds,
                chapterEnd: ch.endSeconds,
                listenedIntervals: listenedIntervals
            )
            return ChapterCoverage(
                id: ch.id,
                chapterTitle: ch.title,
                startSeconds: ch.startSeconds,
                endSeconds: ch.endSeconds,
                coveredFraction: frac,
                listenPassCount: passes
            )
        }
    }

    // MARK: - Time-of-Day Histogram

    /// Distributes total adjusted duration across 24 hour buckets (0–23 in local time).
    static func timeOfDayHistogram(
        segments: [ListeningSegment],
        calendar: Calendar = .current
    ) -> [HourBucket] {
        var hours: [Int: TimeInterval] = [:]
        for segment in segments {
            let startHour = calendar.component(.hour, from: segment.startedAt)
            let endHour = calendar.component(.hour, from: segment.endedAt)
            if startHour == endHour {
                hours[startHour, default: 0] += segment.adjustedDuration
            } else {
                let spannedHours: Int
                if endHour > startHour {
                    spannedHours = endHour - startHour + 1
                } else {
                    spannedHours = (24 - startHour) + endHour + 1
                }
                let share = segment.adjustedDuration / Double(spannedHours)
                var h = startHour
                for _ in 0..<spannedHours {
                    hours[h, default: 0] += share
                    h = (h + 1) % 24
                }
            }
        }
        return (0..<24).map { hour in
            HourBucket(id: hour, totalAdjustedDuration: hours[hour] ?? 0)
        }
    }

    // MARK: - Speed Trend

    /// Weighted daily average speed from segments (weighted by playback duration).
    static func speedTrend(
        segments: [ListeningSegment],
        calendar: Calendar = .current
    ) -> [SpeedTrendPoint] {
        var days: [Date: (weightedSpeed: Double, totalWeight: Double)] = [:]
        for segment in segments {
            let day = calendar.startOfDay(for: segment.startedAt)
            let weight = segment.playbackDuration
            days[day, default: (0, 0)].weightedSpeed += segment.speed * weight
            days[day, default: (0, 0)].totalWeight += weight
        }
        return days.map { day, acc in
            SpeedTrendPoint(
                date: day,
                averageSpeed: acc.totalWeight > 0 ? acc.weightedSpeed / acc.totalWeight : 1.0
            )
        }.sorted { $0.date < $1.date }
    }

    // MARK: - Session-Length Distribution

    static func sessionLengthDistribution(
        segments: [ListeningSegment]
    ) -> [SessionLengthBucket] {
        let boundaries: [(String, Range<TimeInterval>)] = [
            ("0–5m",   0..<300),
            ("5–15m",  300..<900),
            ("15–30m", 900..<1800),
            ("30–60m", 1800..<3600),
            ("60m+",   3600..<TimeInterval.greatestFiniteMagnitude),
        ]
        return boundaries.map { label, range in
            SessionLengthBucket(
                id: label,
                range: range,
                count: segments.filter { range.contains(max(0, $0.wallClockDuration)) }.count
            )
        }
    }

    // MARK: - Retention Curve

    /// "Remembered" = grade >= 3 (passing grade in SM-2).
    nonisolated static func retentionCurve(
        reviews: [(intervalDays: Int, grade: Int)]
    ) -> [RetentionCurvePoint] {
        var groups: [Int: (total: Int, remembered: Int)] = [:]
        for review in reviews {
            groups[review.intervalDays, default: (0, 0)].total += 1
            if review.grade >= 3 {
                groups[review.intervalDays, default: (0, 0)].remembered += 1
            }
        }
        return groups.map { interval, counts in
            RetentionCurvePoint(
                intervalDays: interval,
                retentionRate: Double(counts.remembered) / Double(counts.total)
            )
        }.sorted { $0.intervalDays < $1.intervalDays }
    }

    // MARK: - Due Forecast

    nonisolated static func dueForecast(
        cards: [(nextReviewDate: Date, isEnabled: Bool)],
        days: Int = 30,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> [DueForecastPoint] {
        let today = calendar.startOfDay(for: now)
        let enabled = cards.filter(\.isEnabled)
        return (0..<days).map { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: today) else {
                return DueForecastPoint(id: "", date: today, dueCount: 0)
            }
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: date)!
            let count = enabled.filter { $0.nextReviewDate < dayEnd }.count
            return DueForecastPoint(
                id: ISO8601DateFormatter().string(from: date),
                date: date,
                dueCount: count
            )
        }
    }

    // MARK: - Grade Distribution

    nonisolated static func gradeDistribution(reviews: [Int]) -> [GradeDistribution] {
        var counts: [Int: Int] = [:]
        for grade in reviews { counts[grade, default: 0] += 1 }
        return (0...5).map { grade in
            GradeDistribution(id: grade, grade: grade, count: counts[grade] ?? 0)
        }
    }

    // MARK: - Planner Adherence

    nonisolated static func plannerAdherence(
        plannedSessions: [(startTime: Date, endTime: Date, isCompleted: Bool)],
        listeningSegments: [(startedAt: Date, playbackDuration: TimeInterval)]
    ) -> PlannerAdherence {
        let totalPlanned = plannedSessions.count
        let completed = plannedSessions.filter(\.isCompleted).count
        let totalPlannedDuration = plannedSessions.reduce(0.0) { acc, s in
            acc + s.endTime.timeIntervalSince(s.startTime)
        }

        var actualDuringPlanned: TimeInterval = 0
        for seg in listeningSegments {
            for plan in plannedSessions {
                let overlapStart = max(seg.startedAt, plan.startTime)
                let overlapEnd = min(
                    seg.startedAt.addingTimeInterval(seg.playbackDuration),
                    plan.endTime
                )
                if overlapStart < overlapEnd {
                    actualDuringPlanned += overlapEnd.timeIntervalSince(overlapStart)
                }
            }
        }

        return PlannerAdherence(
            totalPlannedSessions: totalPlanned,
            completedSessions: completed,
            completionRate: totalPlanned > 0 ? Double(completed) / Double(totalPlanned) : 0,
            totalPlannedDuration: totalPlannedDuration,
            actualListenedDuringPlanned: actualDuringPlanned
        )
    }

    // MARK: - Internal Helpers

    private static func aggregate(segments: [ListeningSegment]) -> (playback: TimeInterval, adjusted: TimeInterval) {
        var playback: TimeInterval = 0
        var adjusted: TimeInterval = 0
        for seg in segments {
            playback += seg.playbackDuration
            adjusted += seg.adjustedDuration
        }
        return (playback, adjusted)
    }
}

// MARK: - Calendar Helpers

extension Calendar {
    func startOfPeriod(_ bucket: StatsBucket, for date: Date) -> Date {
        switch bucket {
        case .day:   return startOfDay(for: date)
        case .week:  return dateComponents([.calendar, .timeZone, .yearForWeekOfYear, .weekOfYear], from: date).date ?? date
        case .month: return dateComponents([.calendar, .timeZone, .year, .month], from: date).date ?? date
        case .year:  return dateComponents([.calendar, .timeZone, .year], from: date).date ?? date
        case .all:   return .distantPast
        }
    }

    func endOfPeriod(_ bucket: StatsBucket, for date: Date) -> Date {
        switch bucket {
        case .day:   return self.date(byAdding: .day, value: 1, to: startOfDay(for: date)) ?? date
        case .week:  return self.date(byAdding: .weekOfYear, value: 1, to: startOfPeriod(.week, for: date)) ?? date
        case .month: return self.date(byAdding: .month, value: 1, to: startOfPeriod(.month, for: date)) ?? date
        case .year:  return self.date(byAdding: .year, value: 1, to: startOfPeriod(.year, for: date)) ?? date
        case .all:   return .distantFuture
        }
    }
}
