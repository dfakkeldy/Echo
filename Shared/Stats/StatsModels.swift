import Foundation

// MARK: - Calendar Bucketing

enum StatsBucket: String, CaseIterable, Sendable {
    case day
    case week
    case month
    case year
    case all

    var calendarComponent: Calendar.Component {
        switch self {
        case .day:   return .day
        case .week:  return .weekOfYear
        case .month: return .month
        case .year:  return .year
        case .all:   return .era
        }
    }
}

// MARK: - Listening Segments (raw row shape from playback_event)

struct ListeningSegment: Equatable, Sendable {
    let audiobookID: String
    let trackID: String?
    let startedAt: Date
    let endedAt: Date
    let startPosition: TimeInterval
    let endPosition: TimeInterval
    let speed: Double
    let source: String?

    /// Wall-clock duration of this segment, in seconds.
    var wallClockDuration: TimeInterval { endedAt.timeIntervalSince(startedAt) }

    /// Playback distance covered (position delta), in seconds.
    var playbackDuration: TimeInterval { max(0, endPosition - startPosition) }

    /// Speed-adjusted listening time — the "real" time spent consuming content.
    /// A 10-minute segment at 2× speed = 5 minutes of content consumed.
    var adjustedDuration: TimeInterval {
        speed > 0 ? playbackDuration / speed : playbackDuration
    }
}

// MARK: - Daily Aggregates

struct DailyTotal: Equatable, Sendable {
    let date: Date
    let totalPlaybackDuration: TimeInterval
    let totalAdjustedDuration: TimeInterval
    let segmentCount: Int
}

// MARK: - Bucketed Aggregates

struct BucketTotal: Identifiable, Equatable, Sendable {
    let id: String
    let startDate: Date
    let endDate: Date
    let totalPlaybackDuration: TimeInterval
    let totalAdjustedDuration: TimeInterval
    let segmentCount: Int
}

// MARK: - Per-Book Aggregates

struct BookTotal: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let totalPlaybackDuration: TimeInterval
    let totalAdjustedDuration: TimeInterval
    let segmentCount: Int
}

// MARK: - Speed Trend Data Points

struct SpeedTrendPoint: Equatable, Sendable {
    let date: Date
    let averageSpeed: Double
}

// MARK: - Time-of-Day Histogram

struct HourBucket: Identifiable, Equatable, Sendable {
    /// 0–23 hour of day in local time
    let id: Int
    let totalAdjustedDuration: TimeInterval
}

// MARK: - Session Length Distribution

struct SessionLengthBucket: Identifiable, Equatable, Sendable {
    let id: String
    let range: Range<TimeInterval>
    let count: Int
}

// MARK: - Streak

struct StreakInfo: Equatable, Sendable {
    let currentStreakDays: Int
    let longestStreakDays: Int
    let currentStreakStart: Date?
    let longestStreakStart: Date?
    let longestStreakEnd: Date?
}

// MARK: - Chapter Coverage

struct ChapterCoverage: Identifiable, Equatable, Sendable {
    let id: Int
    let chapterTitle: String
    let startSeconds: TimeInterval
    let endSeconds: TimeInterval
    /// Fraction 0...1 of the chapter that was listened to at least once
    let coveredFraction: Double
    /// How many distinct listening sessions covered part of this chapter
    let listenPassCount: Int
}

// MARK: - SRS / Flashcard Stats

struct SRSStats: Equatable, Sendable {
    let dueCount: Int
    let reviewedToday: Int
    let totalCards: Int
    let retentionRate: Double
    let averageEase: Double
    let totalReviews: Int
}

struct DailyReviewCount: Identifiable, Equatable, Sendable {
    let id: String
    let date: Date
    let count: Int
}

struct GradeDistribution: Identifiable, Equatable, Sendable {
    let id: Int
    let grade: Int
    let count: Int
}

struct DueForecastPoint: Identifiable, Equatable, Sendable {
    let id: String
    let date: Date
    let dueCount: Int
}

// MARK: - Planner Adherence

struct PlannerAdherence: Equatable, Sendable {
    let totalPlannedSessions: Int
    let completedSessions: Int
    let completionRate: Double
    let totalPlannedDuration: TimeInterval
    let actualListenedDuringPlanned: TimeInterval
}

// MARK: - Overview

struct StatsOverview: Equatable, Sendable {
    let totalListeningDuration: TimeInterval
    let todayDuration: TimeInterval
    let streak: StreakInfo
    let dailyAverage: TimeInterval
    let booksListened: Int
    let activeDays: Int
}

// MARK: - Alignment Coverage

struct AlignmentCoverage: Equatable, Sendable {
    let totalEpubBlocks: Int
    let alignedBlocks: Int
    let fractionAligned: Double
}
