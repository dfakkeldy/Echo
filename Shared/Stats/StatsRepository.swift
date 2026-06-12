import Foundation
import GRDB

/// Thin async-read layer that fetches raw rows from GRDB and delegates all math to StatsAggregator.
/// All methods use `try await reader.read { db in ... }` — no writes, no main-actor GRDB.
struct StatsRepository: Sendable {

    let reader: any DatabaseReader

    init(reader: any DatabaseReader) {
        self.reader = reader
    }

    // MARK: - Listening Segments

    func fetchSegments(
        from startDate: Date,
        to endDate: Date,
        audiobookID: String? = nil
    ) async throws -> [ListeningSegment] {
        try await reader.read { db in
            let formatter = ISO8601DateFormatter()
            let startStr = formatter.string(from: startDate)
            let endStr = formatter.string(from: endDate)

            var sql = """
                SELECT audiobook_id, track_id, started_at, ended_at,
                       start_position, end_position, speed, source
                FROM playback_event
                WHERE started_at >= ? AND started_at < ?
                  AND ended_at IS NOT NULL
                  AND event_type = 'play'
                """
            let arguments: StatementArguments
            if let bookID = audiobookID {
                sql += " AND audiobook_id = ?"
                arguments = [startStr, endStr, bookID]
            } else {
                arguments = [startStr, endStr]
            }
            sql += " ORDER BY started_at ASC"

            var segments: [ListeningSegment] = []
            let rows = try Row.fetchCursor(db, sql: sql, arguments: arguments)
            while let row = try rows.next() {
                guard let startedAtStr: String = row["started_at"],
                      let startedAt = formatter.date(from: startedAtStr),
                      let endedAtStr: String = row["ended_at"],
                      let endedAt = formatter.date(from: endedAtStr) else {
                    continue
                }

                segments.append(ListeningSegment(
                    audiobookID: row["audiobook_id"],
                    trackID: row["track_id"],
                    startedAt: startedAt,
                    endedAt: endedAt,
                    startPosition: row["start_position"] ?? 0,
                    endPosition: row["end_position"] ?? 0,
                    speed: row["speed"] ?? 1.0,
                    source: row["source"]
                ))
            }
            return segments
        }
    }

    // MARK: - Active Days

    func fetchActiveDays(
        calendar: Calendar = .current
    ) async throws -> Set<Date> {
        try await reader.read { db in
            let rows = try Row.fetchCursor(db, sql: """
                SELECT DISTINCT started_at FROM playback_event
                WHERE event_type = 'play' AND ended_at IS NOT NULL
                """)
            var days: Set<Date> = []
            let formatter = ISO8601DateFormatter()
            while let row = try rows.next() {
                if let str: String = row["started_at"],
                   let date = formatter.date(from: str) {
                    days.insert(calendar.startOfDay(for: date))
                }
            }
            return days
        }
    }

    // MARK: - Overview

    func fetchOverview(now: Date = Date(), calendar: Calendar = .current) async throws -> StatsOverview {
        let todayStart = calendar.startOfDay(for: now)
        let todayEnd = calendar.date(byAdding: .day, value: 1, to: todayStart)!

        async let segmentsToday = fetchSegments(from: todayStart, to: todayEnd)
        async let allSegments = fetchSegments(from: .distantPast, to: .distantFuture)
        async let activeDays = fetchActiveDays(calendar: calendar)
        async let bookCount = fetchBookCount()

        let today = try await segmentsToday
        let all = try await allSegments
        let days = try await activeDays
        let books = try await bookCount

        let todayDuration = today.reduce(0) { $0 + $1.adjustedDuration }
        let totalDuration = all.reduce(0) { $0 + $1.adjustedDuration }
        let dailyTotals = StatsAggregator.dailyTotals(segments: all, calendar: calendar)
        let avg = days.count > 0 ? totalDuration / Double(days.count) : 0

        return StatsOverview(
            totalListeningDuration: totalDuration,
            todayDuration: todayDuration,
            streak: StatsAggregator.streak(activeDays: days, calendar: calendar, now: now),
            dailyAverage: avg,
            booksListened: books,
            activeDays: days.count
        )
    }

    // MARK: - Bucketed Totals

    func fetchBucketedTotals(
        by bucket: StatsBucket,
        calendar: Calendar = .current,
        now: Date = Date()
    ) async throws -> [BucketTotal] {
        let segments: [ListeningSegment]
        switch bucket {
        case .all:
            segments = try await fetchSegments(from: .distantPast, to: .distantFuture)
        default:
            let lookback: Date
            switch bucket {
            case .day:   lookback = calendar.date(byAdding: .day, value: -30, to: now) ?? now
            case .week:  lookback = calendar.date(byAdding: .month, value: -3, to: now) ?? now
            case .month: lookback = calendar.date(byAdding: .year, value: -1, to: now) ?? now
            case .year:  lookback = calendar.date(byAdding: .year, value: -5, to: now) ?? now
            default:     lookback = .distantPast
            }
            segments = try await fetchSegments(from: lookback, to: now)
        }
        return StatsAggregator.bucket(segments: segments, by: bucket, calendar: calendar, now: now)
    }

    // MARK: - Per-Book Totals

    func fetchPerBookTotals(
        from startDate: Date = .distantPast,
        to endDate: Date = .distantFuture
    ) async throws -> [BookTotal] {
        try await reader.read { db in
            let formatter = ISO8601DateFormatter()
            let startStr = formatter.string(from: startDate)
            let endStr = formatter.string(from: endDate)

            let rows = try Row.fetchCursor(db, sql: """
                SELECT pe.audiobook_id, a.title,
                       SUM(pe.end_position - pe.start_position) as total_playback,
                       SUM((pe.end_position - pe.start_position) / pe.speed) as total_adjusted,
                       COUNT(*) as segment_count
                FROM playback_event pe
                JOIN audiobook a ON a.id = pe.audiobook_id
                WHERE pe.started_at >= ? AND pe.started_at < ?
                  AND pe.ended_at IS NOT NULL
                  AND pe.event_type = 'play'
                GROUP BY pe.audiobook_id
                ORDER BY total_adjusted DESC
                """, arguments: [startStr, endStr])

            var results: [BookTotal] = []
            while let row = try rows.next() {
                results.append(BookTotal(
                    id: row["audiobook_id"],
                    title: row["title"] ?? "Unknown",
                    totalPlaybackDuration: row["total_playback"] ?? 0,
                    totalAdjustedDuration: row["total_adjusted"] ?? 0,
                    segmentCount: row["segment_count"] ?? 0
                ))
            }
            return results
        }
    }

    // MARK: - Speed Trend

    func fetchSpeedTrend(calendar: Calendar = .current) async throws -> [SpeedTrendPoint] {
        let segments = try await fetchSegments(from: .distantPast, to: .distantFuture)
        return StatsAggregator.speedTrend(segments: segments, calendar: calendar)
    }

    // MARK: - Time-of-Day Histogram

    func fetchTimeOfDayHistogram(calendar: Calendar = .current) async throws -> [HourBucket] {
        let segments = try await fetchSegments(from: .distantPast, to: .distantFuture)
        return StatsAggregator.timeOfDayHistogram(segments: segments, calendar: calendar)
    }

    // MARK: - Session Length Distribution

    func fetchSessionLengthDistribution() async throws -> [SessionLengthBucket] {
        let segments = try await fetchSegments(from: .distantPast, to: .distantFuture)
        return StatsAggregator.sessionLengthDistribution(segments: segments)
    }

    // MARK: - Chapter Coverage

    func fetchChapterCoverage(
        audiobookID: String
    ) async throws -> [ChapterCoverage] {
        async let segments = fetchSegments(
            from: .distantPast, to: .distantFuture, audiobookID: audiobookID
        )
        async let chapters = fetchChapters(audiobookID: audiobookID)

        let segs = try await segments
        let chs = try await chapters

        let intervals = segs.map { seg in
            seg.startPosition...seg.endPosition
        }

        return StatsAggregator.chaptersCoverage(chapters: chs, listenedIntervals: intervals)
    }

    // MARK: - SRS Stats

    func fetchSRSStats(now: Date = Date(), calendar: Calendar = .current) async throws -> SRSStats {
        try await reader.read { db in
            let todayStart = calendar.startOfDay(for: now)
            let formatter = ISO8601DateFormatter()
            let nowStr = formatter.string(from: now)
            let todayStr = formatter.string(from: todayStart)

            let dueCount = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM flashcard
                WHERE is_enabled = 1 AND next_review_date <= ?
                """, arguments: [nowStr]) ?? 0

            let reviewedToday = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM real_time_event
                WHERE event_type = 'flashcard_reviewed' AND started_at >= ?
                """, arguments: [todayStr]) ?? 0

            let totalCards = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM flashcard WHERE is_enabled = 1
                """) ?? 0

            let avgEase = try Double.fetchOne(db, sql: """
                SELECT AVG(ease_factor) FROM flashcard WHERE is_enabled = 1
                """) ?? 2.5

            let totalReviews = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM real_time_event WHERE event_type = 'flashcard_reviewed'
                """) ?? 0

            let retainedCount = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM flashcard
                WHERE is_enabled = 1 AND ease_factor >= 2.0
                """) ?? 0

            let retentionRate = totalCards > 0
                ? Double(retainedCount) / Double(totalCards)
                : 0

            return SRSStats(
                dueCount: dueCount,
                reviewedToday: reviewedToday,
                totalCards: totalCards,
                retentionRate: retentionRate,
                averageEase: avgEase,
                totalReviews: totalReviews
            )
        }
    }

    func fetchDailyReviewCounts(
        from startDate: Date = .distantPast,
        to endDate: Date = .distantFuture,
        calendar: Calendar = .current
    ) async throws -> [DailyReviewCount] {
        try await reader.read { db in
            let formatter = ISO8601DateFormatter()
            let startStr = formatter.string(from: startDate)
            let endStr = formatter.string(from: endDate)

            let rows = try Row.fetchCursor(db, sql: """
                SELECT started_at FROM real_time_event
                WHERE event_type = 'flashcard_reviewed'
                  AND started_at >= ? AND started_at < ?
                ORDER BY started_at ASC
                """, arguments: [startStr, endStr])

            var byDay: [Date: Int] = [:]
            while let row = try rows.next() {
                if let str: String = row["started_at"],
                   let date = formatter.date(from: str) {
                    let day = calendar.startOfDay(for: date)
                    byDay[day, default: 0] += 1
                }
            }

            return byDay.map { day, count in
                DailyReviewCount(
                    id: ISO8601DateFormatter().string(from: day),
                    date: day,
                    count: count
                )
            }.sorted { $0.date < $1.date }
        }
    }

    func fetchDueForecast(
        days: Int = 30,
        now: Date = Date(),
        calendar: Calendar = .current
    ) async throws -> [DueForecastPoint] {
        try await reader.read { db in
            let formatter = ISO8601DateFormatter()
            let rows = try Row.fetchCursor(db, sql: """
                SELECT next_review_date, is_enabled FROM flashcard
                WHERE next_review_date IS NOT NULL AND is_enabled = 1
                """)

            var cards: [(nextReviewDate: Date, isEnabled: Bool)] = []
            while let row = try rows.next() {
                if let str: String = row["next_review_date"],
                   let date = formatter.date(from: str) {
                    cards.append((nextReviewDate: date, isEnabled: row["is_enabled"] ?? true))
                }
            }

            return StatsAggregator.dueForecast(cards: cards, days: days, calendar: calendar, now: now)
        }
    }

    func fetchRetentionCurve() async throws -> [(intervalDays: Int, retentionRate: Double)] {
        try await reader.read { db in
            let rows = try Row.fetchCursor(db, sql: """
                SELECT metadata_json FROM real_time_event
                WHERE event_type = 'flashcard_reviewed'
                """)

            var reviews: [(intervalDays: Int, grade: Int)] = []
            while let row = try rows.next() {
                if let jsonStr: String = row["metadata_json"],
                   let data = jsonStr.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let grade = dict["grade"] as? Int,
                   let intervalDays = dict["intervalDays"] as? Int {
                    reviews.append((intervalDays: intervalDays, grade: grade))
                }
            }
            return StatsAggregator.retentionCurve(reviews: reviews)
        }
    }

    func fetchGradeDistribution() async throws -> [GradeDistribution] {
        try await reader.read { db in
            let rows = try Row.fetchCursor(db, sql: """
                SELECT metadata_json FROM real_time_event
                WHERE event_type = 'flashcard_reviewed'
                """)

            var grades: [Int] = []
            while let row = try rows.next() {
                if let jsonStr: String = row["metadata_json"],
                   let data = jsonStr.data(using: .utf8),
                   let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let grade = dict["grade"] as? Int {
                    grades.append(grade)
                }
            }
            return StatsAggregator.gradeDistribution(reviews: grades)
        }
    }

    // MARK: - Alignment Coverage

    func fetchAlignmentCoverage(audiobookID: String) async throws -> AlignmentCoverage {
        try await reader.read { db in
            let total = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM epub_block WHERE audiobook_id = ?
                """, arguments: [audiobookID]) ?? 0

            let aligned = try Int.fetchOne(db, sql: """
                SELECT COUNT(DISTINCT eb.id) FROM epub_block eb
                JOIN alignment_anchor aa ON aa.epub_block_id = eb.id
                WHERE eb.audiobook_id = ?
                """, arguments: [audiobookID]) ?? 0

            return AlignmentCoverage(
                totalEpubBlocks: total,
                alignedBlocks: aligned,
                fractionAligned: total > 0 ? Double(aligned) / Double(total) : 0
            )
        }
    }

    // MARK: - Planner Adherence

    func fetchPlannerAdherence(
        from startDate: Date = .distantPast,
        to endDate: Date = .distantFuture
    ) async throws -> PlannerAdherence {
        try await reader.read { db in
            let formatter = ISO8601DateFormatter()
            let startStr = formatter.string(from: startDate)
            let endStr = formatter.string(from: endDate)

            let planRows = try Row.fetchCursor(db, sql: """
                SELECT start_time, end_time, is_completed FROM planned_session
                WHERE start_time >= ? AND start_time < ?
                """, arguments: [startStr, endStr])

            var plans: [(startTime: Date, endTime: Date, isCompleted: Bool)] = []
            while let row = try planRows.next() {
                if let startTimeStr: String = row["start_time"],
                   let endTimeStr: String = row["end_time"],
                   let start = formatter.date(from: startTimeStr),
                   let end = formatter.date(from: endTimeStr) {
                    plans.append((
                        startTime: start,
                        endTime: end,
                        isCompleted: row["is_completed"] ?? false
                    ))
                }
            }

            let segRows = try Row.fetchCursor(db, sql: """
                SELECT started_at, end_position, start_position
                FROM playback_event
                WHERE event_type = 'play' AND ended_at IS NOT NULL
                  AND started_at >= ? AND started_at < ?
                """, arguments: [startStr, endStr])

            var segments: [(startedAt: Date, playbackDuration: TimeInterval)] = []
            while let row = try segRows.next() {
                if let startedStr: String = row["started_at"],
                   let startedAt = formatter.date(from: startedStr) {
                    let startPos: Double = row["start_position"] ?? 0
                    let endPos: Double = row["end_position"] ?? 0
                    segments.append((
                        startedAt: startedAt,
                        playbackDuration: max(0, endPos - startPos)
                    ))
                }
            }

            return StatsAggregator.plannerAdherence(
                plannedSessions: plans,
                listeningSegments: segments
            )
        }
    }

    // MARK: - Private Helpers

    private func fetchBookCount() async throws -> Int {
        try await reader.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM audiobook") ?? 0
        }
    }

    private func fetchChapters(
        audiobookID: String
    ) async throws -> [(id: Int, title: String, startSeconds: TimeInterval, endSeconds: TimeInterval)] {
        try await reader.read { db in
            let rows = try Row.fetchCursor(db, sql: """
                SELECT id, title, start_seconds, end_seconds
                FROM chapter
                WHERE audiobook_id = ?
                ORDER BY start_seconds ASC
                """, arguments: [audiobookID])

            var chapters: [(id: Int, title: String, startSeconds: TimeInterval, endSeconds: TimeInterval)] = []
            while let row = try rows.next() {
                chapters.append((
                    id: row["id"],
                    title: row["title"] ?? "Untitled",
                    startSeconds: row["start_seconds"] ?? 0,
                    endSeconds: row["end_seconds"] ?? 0
                ))
            }
            return chapters
        }
    }
}
