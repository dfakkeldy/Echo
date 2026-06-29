// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct StatsRepositoryTests {

    private func makeDB() throws -> DatabaseService {
        try DatabaseService(inMemory: ())
    }

    // MARK: - Segments

    @Test func fetchSegmentsReturnsPlaybackEventsInRange() async throws {
        let db = try makeDB()
        let repo = StatsRepository(reader: db.writer)

        let now = Date()
        let formatter = ISO8601DateFormatter()
        try db.write { db in
            try db.execute(
                sql:
                    "INSERT INTO audiobook (id, title, duration, added_at) VALUES ('b1', 'Book 1', 3600, ?)",
                arguments: [formatter.string(from: now)])
            try db.execute(
                sql:
                    "INSERT INTO audiobook (id, title, duration, added_at) VALUES ('b2', 'Book 2', 7200, ?)",
                arguments: [formatter.string(from: now)])
            try db.execute(
                sql: """
                    INSERT INTO playback_event (audiobook_id, started_at, ended_at, start_position, end_position, speed, event_type)
                    VALUES ('b1', ?, ?, 0, 600, 1.0, 'play')
                    """,
                arguments: [
                    formatter.string(from: now.addingTimeInterval(-3600)),
                    formatter.string(from: now.addingTimeInterval(-3000)),
                ])
            try db.execute(
                sql: """
                    INSERT INTO playback_event (audiobook_id, started_at, ended_at, start_position, end_position, speed, event_type)
                    VALUES ('b1', ?, ?, 600, 1200, 2.0, 'play')
                    """,
                arguments: [
                    formatter.string(from: now.addingTimeInterval(-1800)),
                    formatter.string(from: now.addingTimeInterval(-1200)),
                ])
        }

        let segments = try await repo.fetchSegments(
            from: now.addingTimeInterval(-7200),
            to: now
        )

        #expect(segments.count == 2)
        #expect(segments[0].audiobookID == "b1")
        #expect(segments[0].speed == 1.0)
        #expect(segments[1].speed == 2.0)
        #expect(segments[1].adjustedDuration == 300)
    }

    @Test func fetchChapterCoverageToleratesInvertedSegment() async throws {
        let db = try makeDB()
        let repo = StatsRepository(reader: db.writer)
        let now = Date()
        let f = ISO8601DateFormatter()
        try db.write { db in
            try db.execute(
                sql:
                    "INSERT INTO audiobook (id, title, duration, added_at) VALUES ('b1', 'B1', 3600, ?)",
                arguments: [f.string(from: now)])
            // end_position < start_position must not trap on `start...end`.
            try db.execute(
                sql: """
                    INSERT INTO playback_event (audiobook_id, started_at, ended_at, start_position, end_position, speed, event_type)
                    VALUES ('b1', ?, ?, 100, 50, 1.0, 'play')
                    """,
                arguments: [f.string(from: now.addingTimeInterval(-100)), f.string(from: now)])
        }

        let coverage = try await repo.fetchChapterCoverage(audiobookID: "b1")
        #expect(coverage.isEmpty)  // no chapters; the point is it returns without crashing
    }

    @Test func fetchSegmentsFiltersByAudiobook() async throws {
        let db = try makeDB()
        let repo = StatsRepository(reader: db.writer)

        let now = Date()
        let formatter = ISO8601DateFormatter()
        try db.write { db in
            try db.execute(
                sql:
                    "INSERT INTO audiobook (id, title, duration, added_at) VALUES ('b1', 'B1', 3600, ?)",
                arguments: [formatter.string(from: now)])
            try db.execute(
                sql:
                    "INSERT INTO audiobook (id, title, duration, added_at) VALUES ('b2', 'B2', 3600, ?)",
                arguments: [formatter.string(from: now)])
            try db.execute(
                sql: """
                    INSERT INTO playback_event (audiobook_id, started_at, ended_at, start_position, end_position, speed, event_type)
                    VALUES ('b1', ?, ?, 0, 100, 1.0, 'play')
                    """,
                arguments: [
                    formatter.string(from: now.addingTimeInterval(-600)),
                    formatter.string(from: now),
                ])
            try db.execute(
                sql: """
                    INSERT INTO playback_event (audiobook_id, started_at, ended_at, start_position, end_position, speed, event_type)
                    VALUES ('b2', ?, ?, 0, 200, 1.0, 'play')
                    """,
                arguments: [
                    formatter.string(from: now.addingTimeInterval(-300)),
                    formatter.string(from: now),
                ])
        }

        let b1Segments = try await repo.fetchSegments(
            from: .distantPast, to: .distantFuture, audiobookID: "b1"
        )
        #expect(b1Segments.count == 1)
        #expect(b1Segments[0].audiobookID == "b1")
    }

    @Test func fetchSegmentsExcludesNonPlayEvents() async throws {
        let db = try makeDB()
        let repo = StatsRepository(reader: db.writer)

        let now = Date()
        let formatter = ISO8601DateFormatter()
        try db.write { db in
            try db.execute(
                sql:
                    "INSERT INTO audiobook (id, title, duration, added_at) VALUES ('b1', 'B1', 3600, ?)",
                arguments: [formatter.string(from: now)])
            try db.execute(
                sql: """
                    INSERT INTO playback_event (audiobook_id, started_at, ended_at, start_position, end_position, speed, event_type)
                    VALUES ('b1', ?, ?, 0, 100, 1.0, 'seek')
                    """,
                arguments: [
                    formatter.string(from: now.addingTimeInterval(-600)),
                    formatter.string(from: now),
                ])
        }

        let segments = try await repo.fetchSegments(from: .distantPast, to: .distantFuture)
        #expect(segments.isEmpty)
    }

    // MARK: - Overview

    @Test func fetchOverviewAggregatesCorrectly() async throws {
        let db = try makeDB()
        let repo = StatsRepository(reader: db.writer)

        let now = Date()
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let formatter = ISO8601DateFormatter()

        try db.write { db in
            try db.execute(
                sql:
                    "INSERT INTO audiobook (id, title, duration, added_at) VALUES ('b1', 'Book 1', 3600, ?)",
                arguments: [formatter.string(from: now)])

            try db.execute(
                sql: """
                    INSERT INTO playback_event (audiobook_id, started_at, ended_at, start_position, end_position, speed, event_type)
                    VALUES ('b1', ?, ?, 0, 600, 1.0, 'play')
                    """,
                arguments: [
                    formatter.string(from: today.addingTimeInterval(3600)),
                    formatter.string(from: today.addingTimeInterval(4200)),
                ])

            let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
            try db.execute(
                sql: """
                    INSERT INTO playback_event (audiobook_id, started_at, ended_at, start_position, end_position, speed, event_type)
                    VALUES ('b1', ?, ?, 0, 300, 1.0, 'play')
                    """,
                arguments: [
                    formatter.string(from: yesterday.addingTimeInterval(7200)),
                    formatter.string(from: yesterday.addingTimeInterval(7500)),
                ])
        }

        let overview = try await repo.fetchOverview(now: now, calendar: cal)

        #expect(overview.todayDuration == 600)
        #expect(overview.totalListeningDuration == 900)
        #expect(overview.booksListened == 1)
        #expect(overview.activeDays == 2)
        #expect(overview.streak.currentStreakDays == 2)
    }

    // MARK: - Per-Book Totals

    @Test func fetchPerBookTotalsGroupsByBook() async throws {
        let db = try makeDB()
        let repo = StatsRepository(reader: db.writer)

        let now = Date()
        let formatter = ISO8601DateFormatter()
        try db.write { db in
            try db.execute(
                sql:
                    "INSERT INTO audiobook (id, title, duration, added_at) VALUES ('b1', 'Most Listened', 3600, ?)",
                arguments: [formatter.string(from: now)])
            try db.execute(
                sql:
                    "INSERT INTO audiobook (id, title, duration, added_at) VALUES ('b2', 'Least Listened', 3600, ?)",
                arguments: [formatter.string(from: now)])
            try db.execute(
                sql: """
                    INSERT INTO playback_event (audiobook_id, started_at, ended_at, start_position, end_position, speed, event_type)
                    VALUES ('b1', ?, ?, 0, 1000, 1.0, 'play')
                    """,
                arguments: [
                    formatter.string(from: now.addingTimeInterval(-3600)),
                    formatter.string(from: now.addingTimeInterval(-2600)),
                ])
            try db.execute(
                sql: """
                    INSERT INTO playback_event (audiobook_id, started_at, ended_at, start_position, end_position, speed, event_type)
                    VALUES ('b2', ?, ?, 0, 200, 1.0, 'play')
                    """,
                arguments: [
                    formatter.string(from: now.addingTimeInterval(-1800)),
                    formatter.string(from: now.addingTimeInterval(-1600)),
                ])
        }

        let totals = try await repo.fetchPerBookTotals()
        #expect(totals.count == 2)
        #expect(totals[0].totalAdjustedDuration > totals[1].totalAdjustedDuration)
        #expect(totals[0].title == "Most Listened")
    }

    @Test func fetchSpeedTrendUsesWeightedDailyPlaybackSpeed() async throws {
        let db = try makeDB()
        let repo = StatsRepository(reader: db.writer)

        let cal = Calendar(identifier: .gregorian)
        var components = DateComponents(timeZone: TimeZone(secondsFromGMT: 0))
        components.year = 2026
        components.month = 6
        components.day = 25
        components.hour = 8
        let morning = try #require(cal.date(from: components))
        components.hour = 10
        let lateMorning = try #require(cal.date(from: components))
        let formatter = ISO8601DateFormatter()

        try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO audiobook (id, title, duration, added_at)
                    VALUES ('b1', 'B1', 3600, ?)
                    """, arguments: [formatter.string(from: morning)])
            try db.execute(
                sql: """
                    INSERT INTO playback_event (
                        audiobook_id, started_at, ended_at,
                        start_position, end_position, speed, event_type
                    )
                    VALUES
                        ('b1', ?, ?, 0, 600, 1.0, 'play'),
                        ('b1', ?, ?, 600, 1800, 2.0, 'play')
                    """,
                arguments: [
                    formatter.string(from: morning),
                    formatter.string(from: morning.addingTimeInterval(600)),
                    formatter.string(from: lateMorning),
                    formatter.string(from: lateMorning.addingTimeInterval(600)),
                ])
        }

        let trend = try await repo.fetchSpeedTrend(calendar: cal)

        #expect(trend.count == 1)
        #expect(abs((trend.first?.averageSpeed ?? 0) - 1.67) < 0.01)
    }

    @Test func fetchTimeOfDayHistogramUsesPersistedPlaybackEvents() async throws {
        let db = try makeDB()
        let repo = StatsRepository(reader: db.writer)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))

        try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO audiobook (id, title, duration, added_at)
                    VALUES ('b1', 'B1', 3600, '2026-06-25T08:00:00Z')
                    """)
            try db.execute(
                sql: """
                    INSERT INTO playback_event (
                        audiobook_id, started_at, ended_at,
                        start_position, end_position, speed, event_type
                    )
                    VALUES ('b1', '2026-06-25T08:00:00Z', '2026-06-25T08:30:00Z', 0, 1800, 1.0, 'play')
                    """)
        }

        let histogram = try await repo.fetchTimeOfDayHistogram(calendar: calendar)

        #expect(histogram.count == 24)
        #expect(histogram[8].totalAdjustedDuration == 1800)
        #expect(histogram[7].totalAdjustedDuration == 0)
        #expect(histogram[9].totalAdjustedDuration == 0)
    }

    // MARK: - SRS Stats

    @Test func fetchSRSStatsComputesCorrectly() async throws {
        let db = try makeDB()
        let repo = StatsRepository(reader: db.writer)

        let now = Date()
        let cal = Calendar.current
        let formatter = ISO8601DateFormatter()

        try db.write { db in
            try db.execute(
                sql:
                    "INSERT INTO audiobook (id, title, duration, added_at) VALUES ('b1', 'B1', 3600, ?)",
                arguments: [formatter.string(from: now)])
            try db.execute(
                sql: """
                    INSERT INTO flashcard (id, audiobook_id, front_text, back_text, media_timestamp, ease_factor, is_enabled, next_review_date)
                    VALUES ('c1', 'b1', 'front', 'back', 0, 2.5, 1, ?)
                    """, arguments: [formatter.string(from: now.addingTimeInterval(-86400))])
            try db.execute(
                sql: """
                    INSERT INTO flashcard (id, audiobook_id, front_text, back_text, media_timestamp, ease_factor, is_enabled, next_review_date)
                    VALUES ('c2', 'b1', 'front', 'back', 0, 1.8, 1, ?)
                    """, arguments: [formatter.string(from: now.addingTimeInterval(86400))])
            try db.execute(
                sql: """
                    INSERT INTO flashcard (id, audiobook_id, front_text, back_text, media_timestamp, ease_factor, is_enabled, next_review_date)
                    VALUES ('c3', 'b1', 'front', 'back', 0, 2.5, 0, ?)
                    """, arguments: [formatter.string(from: now)])
            try db.execute(
                sql: """
                    INSERT INTO flashcard (
                        id, audiobook_id, front_text, back_text, media_timestamp,
                        ease_factor, is_enabled, next_review_date, repetitions, last_reviewed_at, card_type
                    )
                    VALUES ('fresh-assignment', 'b1', 'chapter', 'prompt', 0, 2.5, 1, NULL, 0, NULL, 'listening_assignment')
                    """)
            try db.execute(
                sql: """
                    INSERT INTO flashcard (
                        id, audiobook_id, front_text, back_text, media_timestamp,
                        ease_factor, is_enabled, next_review_date, repetitions, last_reviewed_at, card_type
                    )
                    VALUES ('reviewed-unscheduled', 'b1', 'reviewed', 'prompt', 0, 3.0, 1, NULL, 1, ?, 'listening_assignment')
                    """, arguments: [formatter.string(from: now.addingTimeInterval(-3_600))])
        }

        let stats = try await repo.fetchSRSStats(now: now, calendar: cal)
        #expect(stats.dueCount == 1)
        #expect(stats.totalCards == 3)
        #expect(abs(stats.averageEase - 2.43) < 0.01)
        #expect(abs(stats.retentionRate - 0.67) < 0.01)
    }

    @Test func fetchReviewInsightsDecodeIntervalsGradesAndDailyCounts() async throws {
        let db = try makeDB()
        let repo = StatsRepository(reader: db.writer)

        let cal = Calendar(identifier: .gregorian)
        var components = DateComponents(timeZone: TimeZone(secondsFromGMT: 0))
        components.year = 2026
        components.month = 6
        components.day = 25
        components.hour = 12
        let now = try #require(cal.date(from: components))
        let yesterday = try #require(cal.date(byAdding: .day, value: -1, to: now))
        let formatter = ISO8601DateFormatter()

        try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO audiobook (id, title, duration, added_at)
                    VALUES ('b1', 'B1', 3600, ?)
                    """, arguments: [formatter.string(from: now)])
            try db.execute(
                sql: """
                    INSERT INTO flashcard (
                        id, audiobook_id, front_text, back_text, media_timestamp,
                        ease_factor, is_enabled, next_review_date, interval_days, repetitions
                    )
                    VALUES
                        ('c1', 'b1', 'front 1', 'back', 0, 2.5, 1, ?, 7, 1),
                        ('c2', 'b1', 'front 2', 'back', 0, 2.5, 1, ?, 30, 1)
                    """,
                arguments: [
                    formatter.string(from: now),
                    formatter.string(from: now),
                ])
            try db.execute(
                sql: """
                    INSERT INTO real_time_event (
                        id, event_type, audiobook_id, media_timestamp, started_at, ended_at,
                        title, subtitle, metadata_json, source_item_id, source_item_type
                    )
                    VALUES
                        ('r1', 'flashcard_reviewed', 'b1', 0, ?, ?, 'front 1', 'Grade: 4',
                         '{"cardId":"c1","grade":4,"intervalDays":7}', 'c1', 'flashcard'),
                        ('r2', 'flashcard_reviewed', 'b1', 0, ?, ?, 'front 2', 'Grade: 2',
                         '{"cardId":"c2","grade":2}', 'c2', 'flashcard')
                    """,
                arguments: [
                    formatter.string(from: now),
                    formatter.string(from: now),
                    formatter.string(from: yesterday),
                    formatter.string(from: yesterday),
                ])
        }

        let retention = try await repo.fetchRetentionCurve()
        let grades = try await repo.fetchGradeDistribution()
        let daily = try await repo.fetchDailyReviewCounts(calendar: cal)

        #expect(retention.count == 2)
        #expect(retention.first { $0.intervalDays == 7 }?.retentionRate == 1.0)
        #expect(retention.first { $0.intervalDays == 30 }?.retentionRate == 0.0)
        #expect(grades.first { $0.grade == 4 }?.count == 1)
        #expect(grades.first { $0.grade == 2 }?.count == 1)
        #expect(daily.map(\.count).reduce(0, +) == 2)
    }

    // MARK: - Chapter Coverage

    @Test func fetchChapterCoverageReturnsOrderedCoverageForPersistedChapters() async throws {
        let db = try makeDB()
        let repo = StatsRepository(reader: db.writer)

        try db.write { db in
            try db.execute(
                sql: """
                    INSERT INTO audiobook (id, title, duration, added_at)
                    VALUES ('b1', 'B1', 3600, '2026-06-25T08:00:00Z')
                    """)
            try db.execute(
                sql: """
                    INSERT INTO chapter (audiobook_id, title, start_seconds, end_seconds, sort_order)
                    VALUES
                        ('b1', 'Chapter Two', 100, 200, 1),
                        ('b1', 'Chapter One', 0, 100, 0)
                    """)
            try db.execute(
                sql: """
                    INSERT INTO playback_event (
                        audiobook_id, started_at, ended_at,
                        start_position, end_position, speed, event_type
                    )
                    VALUES ('b1', '2026-06-25T08:00:00Z', '2026-06-25T08:02:00Z', 25, 175, 1.0, 'play')
                    """)
        }

        let coverage = try await repo.fetchChapterCoverage(audiobookID: "b1")

        #expect(coverage.map(\.chapterTitle) == ["Chapter One", "Chapter Two"])
        #expect(abs((coverage.first?.coveredFraction ?? 0) - 0.75) < 0.01)
        #expect(abs((coverage.last?.coveredFraction ?? 0) - 0.75) < 0.01)
        #expect(coverage.map(\.listenPassCount) == [1, 1])
    }

    @Test func fetchChapterCoverageNormalizesInvertedPlaybackRanges() async throws {
        let db = try makeDB()
        let repo = StatsRepository(reader: db.writer)

        try db.write { db in
            try db.execute(sql: """
                INSERT INTO audiobook (id, title, duration, added_at)
                VALUES ('b1', 'B1', 3600, '2026-06-25T08:00:00Z')
                """)
            try db.execute(sql: """
                INSERT INTO chapter (audiobook_id, title, start_seconds, end_seconds, sort_order)
                VALUES ('b1', 'Chapter One', 0, 100, 0)
                """)
            try db.execute(sql: """
                INSERT INTO playback_event (
                    audiobook_id, started_at, ended_at,
                    start_position, end_position, speed, event_type
                )
                VALUES ('b1', '2026-06-25T08:00:00Z', '2026-06-25T08:02:00Z', 100, 50, 1.0, 'play')
                """)
        }

        let coverage = try await repo.fetchChapterCoverage(audiobookID: "b1")

        #expect(coverage.map(\.chapterTitle) == ["Chapter One"])
        #expect(abs((coverage.first?.coveredFraction ?? 0) - 0.5) < 0.01)
        #expect(coverage.first?.listenPassCount == 1)
    }

    // MARK: - Alignment Coverage

    @Test func fetchAlignmentCoverage() async throws {
        let db = try makeDB()
        let repo = StatsRepository(reader: db.writer)

        let now = Date()
        let formatter = ISO8601DateFormatter()
        try db.write { db in
            try db.execute(
                sql:
                    "INSERT INTO audiobook (id, title, duration, added_at) VALUES ('b1', 'B1', 3600, ?)",
                arguments: [formatter.string(from: now)])
            for i in 0..<3 {
                try db.execute(
                    sql: """
                        INSERT INTO epub_block (id, audiobook_id, text, block_kind, spine_href, spine_index, block_index, sequence_index)
                        VALUES (?, 'b1', 'text', 'p', ?, ?, ?, ?)
                        """, arguments: ["block-\(i)", "chapter\(i).xhtml", i, i, i])
            }
            try db.execute(
                sql: """
                    INSERT INTO alignment_anchor (id, audiobook_id, epub_block_id, audio_time, anchor_kind, source)
                    VALUES ('a1', 'b1', 'block-0', 0, 'manual', 'user')
                    """)
            try db.execute(
                sql: """
                    INSERT INTO alignment_anchor (id, audiobook_id, epub_block_id, audio_time, anchor_kind, source)
                    VALUES ('a2', 'b1', 'block-1', 120, 'manual', 'user')
                    """)
        }

        let coverage = try await repo.fetchAlignmentCoverage(audiobookID: "b1")
        #expect(coverage.totalEpubBlocks == 3)
        #expect(coverage.alignedBlocks == 2)
        #expect(abs(coverage.fractionAligned - 2.0 / 3.0) < 0.01)
    }

    // MARK: - Planner Adherence

    @Test func fetchPlannerAdherenceMeasuresOverlap() async throws {
        let db = try makeDB()
        let repo = StatsRepository(reader: db.writer)

        let now = Date()
        let formatter = ISO8601DateFormatter()

        try db.write { db in
            try db.execute(
                sql:
                    "INSERT INTO audiobook (id, title, duration, added_at) VALUES ('b1', 'B1', 3600, ?)",
                arguments: [formatter.string(from: now)])
            try db.execute(
                sql: """
                    INSERT INTO planned_session (id, audiobook_id, title, start_time, end_time, is_completed)
                    VALUES ('p1', 'b1', 'Morning Study', ?, ?, 1)
                    """,
                arguments: [
                    formatter.string(from: now.addingTimeInterval(-3600)),
                    formatter.string(from: now.addingTimeInterval(-1800)),
                ])
            try db.execute(
                sql: """
                    INSERT INTO playback_event (audiobook_id, started_at, ended_at, start_position, end_position, speed, event_type)
                    VALUES ('b1', ?, ?, 0, 600, 1.0, 'play')
                    """,
                arguments: [
                    formatter.string(from: now.addingTimeInterval(-3000)),
                    formatter.string(from: now.addingTimeInterval(-2400)),
                ])
        }

        let adherence = try await repo.fetchPlannerAdherence()
        #expect(adherence.totalPlannedSessions == 1)
        #expect(adherence.completedSessions == 1)
        #expect(adherence.actualListenedDuringPlanned == 600)
    }

    // MARK: - Empty State

    @Test func emptyDatabaseReturnsZeros() async throws {
        let db = try makeDB()
        let repo = StatsRepository(reader: db.writer)

        let overview = try await repo.fetchOverview()
        #expect(overview.totalListeningDuration == 0)
        #expect(overview.todayDuration == 0)
        #expect(overview.booksListened == 0)
        #expect(overview.streak.currentStreakDays == 0)

        let segments = try await repo.fetchSegments(from: .distantPast, to: .distantFuture)
        #expect(segments.isEmpty)

        let srs = try await repo.fetchSRSStats()
        #expect(srs.totalCards == 0)
        #expect(srs.dueCount == 0)
    }
}
