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
        try await db.write { db in
            try db.execute(sql: "INSERT INTO audiobook (id, title, duration, added_at) VALUES ('b1', 'Book 1', 3600, ?)",
                           arguments: [formatter.string(from: now)])
            try db.execute(sql: "INSERT INTO audiobook (id, title, duration, added_at) VALUES ('b2', 'Book 2', 7200, ?)",
                           arguments: [formatter.string(from: now)])
            try db.execute(sql: """
                INSERT INTO playback_event (audiobook_id, started_at, ended_at, start_position, end_position, speed, event_type)
                VALUES ('b1', ?, ?, 0, 600, 1.0, 'play')
                """, arguments: [
                    formatter.string(from: now.addingTimeInterval(-3600)),
                    formatter.string(from: now.addingTimeInterval(-3000)),
                ])
            try db.execute(sql: """
                INSERT INTO playback_event (audiobook_id, started_at, ended_at, start_position, end_position, speed, event_type)
                VALUES ('b1', ?, ?, 600, 1200, 2.0, 'play')
                """, arguments: [
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

    @Test func fetchSegmentsFiltersByAudiobook() async throws {
        let db = try makeDB()
        let repo = StatsRepository(reader: db.writer)

        let now = Date()
        let formatter = ISO8601DateFormatter()
        try await db.write { db in
            try db.execute(sql: "INSERT INTO audiobook (id, title, duration, added_at) VALUES ('b1', 'B1', 3600, ?)",
                           arguments: [formatter.string(from: now)])
            try db.execute(sql: "INSERT INTO audiobook (id, title, duration, added_at) VALUES ('b2', 'B2', 3600, ?)",
                           arguments: [formatter.string(from: now)])
            try db.execute(sql: """
                INSERT INTO playback_event (audiobook_id, started_at, ended_at, start_position, end_position, speed, event_type)
                VALUES ('b1', ?, ?, 0, 100, 1.0, 'play')
                """, arguments: [
                    formatter.string(from: now.addingTimeInterval(-600)),
                    formatter.string(from: now),
                ])
            try db.execute(sql: """
                INSERT INTO playback_event (audiobook_id, started_at, ended_at, start_position, end_position, speed, event_type)
                VALUES ('b2', ?, ?, 0, 200, 1.0, 'play')
                """, arguments: [
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
        try await db.write { db in
            try db.execute(sql: "INSERT INTO audiobook (id, title, duration, added_at) VALUES ('b1', 'B1', 3600, ?)",
                           arguments: [formatter.string(from: now)])
            try db.execute(sql: """
                INSERT INTO playback_event (audiobook_id, started_at, ended_at, start_position, end_position, speed, event_type)
                VALUES ('b1', ?, ?, 0, 100, 1.0, 'seek')
                """, arguments: [
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

        try await db.write { db in
            try db.execute(sql: "INSERT INTO audiobook (id, title, duration, added_at) VALUES ('b1', 'Book 1', 3600, ?)",
                           arguments: [formatter.string(from: now)])

            try db.execute(sql: """
                INSERT INTO playback_event (audiobook_id, started_at, ended_at, start_position, end_position, speed, event_type)
                VALUES ('b1', ?, ?, 0, 600, 1.0, 'play')
                """, arguments: [
                    formatter.string(from: today.addingTimeInterval(3600)),
                    formatter.string(from: today.addingTimeInterval(4200)),
                ])

            let yesterday = cal.date(byAdding: .day, value: -1, to: today)!
            try db.execute(sql: """
                INSERT INTO playback_event (audiobook_id, started_at, ended_at, start_position, end_position, speed, event_type)
                VALUES ('b1', ?, ?, 0, 300, 1.0, 'play')
                """, arguments: [
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
        try await db.write { db in
            try db.execute(sql: "INSERT INTO audiobook (id, title, duration, added_at) VALUES ('b1', 'Most Listened', 3600, ?)",
                           arguments: [formatter.string(from: now)])
            try db.execute(sql: "INSERT INTO audiobook (id, title, duration, added_at) VALUES ('b2', 'Least Listened', 3600, ?)",
                           arguments: [formatter.string(from: now)])
            try db.execute(sql: """
                INSERT INTO playback_event (audiobook_id, started_at, ended_at, start_position, end_position, speed, event_type)
                VALUES ('b1', ?, ?, 0, 1000, 1.0, 'play')
                """, arguments: [
                    formatter.string(from: now.addingTimeInterval(-3600)),
                    formatter.string(from: now.addingTimeInterval(-2600)),
                ])
            try db.execute(sql: """
                INSERT INTO playback_event (audiobook_id, started_at, ended_at, start_position, end_position, speed, event_type)
                VALUES ('b2', ?, ?, 0, 200, 1.0, 'play')
                """, arguments: [
                    formatter.string(from: now.addingTimeInterval(-1800)),
                    formatter.string(from: now.addingTimeInterval(-1600)),
                ])
        }

        let totals = try await repo.fetchPerBookTotals()
        #expect(totals.count == 2)
        #expect(totals[0].totalAdjustedDuration > totals[1].totalAdjustedDuration)
        #expect(totals[0].title == "Most Listened")
    }

    // MARK: - SRS Stats

    @Test func fetchSRSStatsComputesCorrectly() async throws {
        let db = try makeDB()
        let repo = StatsRepository(reader: db.writer)

        let now = Date()
        let cal = Calendar.current
        let formatter = ISO8601DateFormatter()

        try await db.write { db in
            try db.execute(sql: "INSERT INTO audiobook (id, title, duration, added_at) VALUES ('b1', 'B1', 3600, ?)",
                           arguments: [formatter.string(from: now)])
            try db.execute(sql: """
                INSERT INTO flashcard (id, audiobook_id, front_text, back_text, media_timestamp, ease_factor, is_enabled, next_review_date)
                VALUES ('c1', 'b1', 'front', 'back', 0, 2.5, 1, ?)
                """, arguments: [formatter.string(from: now.addingTimeInterval(-86400))])
            try db.execute(sql: """
                INSERT INTO flashcard (id, audiobook_id, front_text, back_text, media_timestamp, ease_factor, is_enabled, next_review_date)
                VALUES ('c2', 'b1', 'front', 'back', 0, 1.8, 1, ?)
                """, arguments: [formatter.string(from: now.addingTimeInterval(86400))])
            try db.execute(sql: """
                INSERT INTO flashcard (id, audiobook_id, front_text, back_text, media_timestamp, ease_factor, is_enabled, next_review_date)
                VALUES ('c3', 'b1', 'front', 'back', 0, 2.5, 0, ?)
                """, arguments: [formatter.string(from: now)])
        }

        let stats = try await repo.fetchSRSStats(now: now, calendar: cal)
        #expect(stats.dueCount == 1)
        #expect(stats.totalCards == 2)
        #expect(abs(stats.averageEase - 2.15) < 0.01)
        #expect(stats.retentionRate == 0.5)
    }

    // MARK: - Alignment Coverage

    @Test func fetchAlignmentCoverage() async throws {
        let db = try makeDB()
        let repo = StatsRepository(reader: db.writer)

        let now = Date()
        let formatter = ISO8601DateFormatter()
        try await db.write { db in
            try db.execute(sql: "INSERT INTO audiobook (id, title, duration, added_at) VALUES ('b1', 'B1', 3600, ?)",
                           arguments: [formatter.string(from: now)])
            for i in 0..<3 {
                try db.execute(sql: """
                    INSERT INTO epub_block (id, audiobook_id, text, block_kind, spine_href, spine_index, block_index, sequence_index)
                    VALUES (?, 'b1', 'text', 'p', ?, ?, ?, ?)
                    """, arguments: ["block-\(i)", "chapter\(i).xhtml", i, i, i])
            }
            try db.execute(sql: """
                INSERT INTO alignment_anchor (id, audiobook_id, epub_block_id, audio_time, anchor_kind, source)
                VALUES ('a1', 'b1', 'block-0', 0, 'manual', 'user')
                """)
            try db.execute(sql: """
                INSERT INTO alignment_anchor (id, audiobook_id, epub_block_id, audio_time, anchor_kind, source)
                VALUES ('a2', 'b1', 'block-1', 120, 'manual', 'user')
                """)
        }

        let coverage = try await repo.fetchAlignmentCoverage(audiobookID: "b1")
        #expect(coverage.totalEpubBlocks == 3)
        #expect(coverage.alignedBlocks == 2)
        #expect(abs(coverage.fractionAligned - 2.0/3.0) < 0.01)
    }

    // MARK: - Planner Adherence

    @Test func fetchPlannerAdherenceMeasuresOverlap() async throws {
        let db = try makeDB()
        let repo = StatsRepository(reader: db.writer)

        let now = Date()
        let formatter = ISO8601DateFormatter()

        try await db.write { db in
            try db.execute(sql: "INSERT INTO audiobook (id, title, duration, added_at) VALUES ('b1', 'B1', 3600, ?)",
                           arguments: [formatter.string(from: now)])
            try db.execute(sql: """
                INSERT INTO planned_session (id, audiobook_id, title, start_time, end_time, is_completed)
                VALUES ('p1', 'b1', 'Morning Study', ?, ?, 1)
                """, arguments: [
                    formatter.string(from: now.addingTimeInterval(-3600)),
                    formatter.string(from: now.addingTimeInterval(-1800)),
                ])
            try db.execute(sql: """
                INSERT INTO playback_event (audiobook_id, started_at, ended_at, start_position, end_position, speed, event_type)
                VALUES ('b1', ?, ?, 0, 600, 1.0, 'play')
                """, arguments: [
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
