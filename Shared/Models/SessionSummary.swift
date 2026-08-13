// SPDX-License-Identifier: GPL-3.0-or-later

import CoreLocation
import Foundation

/// One GPS sample captured during a session, in chronological order.
// `nonisolated`: a pure `Sendable` value type. Under the iOS target's Swift 6
// MainActor default isolation its memberwise init would otherwise be inferred
// `@MainActor`, which the `nonisolated` `SessionSummaryService` cannot call.
public nonisolated struct SessionRoutePoint: Codable, Hashable, Sendable {
    public let latitude: Double
    public let longitude: Double
    public let placeName: String?
    public let timestamp: Date

    public init(latitude: Double, longitude: Double, placeName: String?, timestamp: Date) {
        self.latitude = latitude
        self.longitude = longitude
        self.placeName = placeName
        self.timestamp = timestamp
    }

    public var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

/// A reconstructed listening session for one audiobook.
///
/// Sessions are NOT stored: there is no `playback_session` table. This value is
/// derived by `SessionSummaryService` by grouping `playback_event` rows on
/// `started_at`/`ended_at` time gaps, then joining `session_location`, `chapter`,
/// `bookmark`, `flashcard`, and `note`.
// `nonisolated` for the same reason as `SessionRoutePoint` above: a pure
// `Sendable` value built off-actor by `SessionSummaryService`.
public nonisolated struct SessionSummary: Identifiable, Codable, Hashable, Sendable {
    /// Stable synthetic id = "<audiobookID>#<sessionStart ISO8601>".
    public let id: String
    public let audiobookID: String
    /// Wall-clock window of the session (earliest started_at … latest ended_at).
    public let startedAt: Date
    public let endedAt: Date
    /// Audio position range covered (seconds into the audiobook).
    public let startPosition: TimeInterval
    public let endPosition: TimeInterval
    /// Adjusted listening minutes = sum(end_position - start_position) / speed, / 60.
    public let minutesListened: Double
    /// Covered chapter range by `chapter.sort_order` (nil if no chapter overlap).
    public let firstChapterTitle: String?
    public let lastChapterTitle: String?
    public let firstChapterSortOrder: Int?
    public let lastChapterSortOrder: Int?
    /// Counts within the wall-clock window.
    public let bookmarkCount: Int
    public let cardCount: Int
    public let noteCount: Int
    public let imageCount: Int
    /// GPS route in chronological order (empty if location was off).
    public let route: [SessionRoutePoint]
    /// Route distance in miles (0 if route has < 2 points).
    public let routeMiles: Double

    public init(
        id: String,
        audiobookID: String,
        startedAt: Date,
        endedAt: Date,
        startPosition: TimeInterval,
        endPosition: TimeInterval,
        minutesListened: Double,
        firstChapterTitle: String?,
        lastChapterTitle: String?,
        firstChapterSortOrder: Int?,
        lastChapterSortOrder: Int?,
        bookmarkCount: Int,
        cardCount: Int,
        noteCount: Int,
        imageCount: Int,
        route: [SessionRoutePoint],
        routeMiles: Double
    ) {
        self.id = id
        self.audiobookID = audiobookID
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.startPosition = startPosition
        self.endPosition = endPosition
        self.minutesListened = minutesListened
        self.firstChapterTitle = firstChapterTitle
        self.lastChapterTitle = lastChapterTitle
        self.firstChapterSortOrder = firstChapterSortOrder
        self.lastChapterSortOrder = lastChapterSortOrder
        self.bookmarkCount = bookmarkCount
        self.cardCount = cardCount
        self.noteCount = noteCount
        self.imageCount = imageCount
        self.route = route
        self.routeMiles = routeMiles
    }

    /// True when location was recorded for this session.
    public var hasRoute: Bool { route.count >= 2 }

    /// Human chapter-range label, e.g. "Ch. 3 – Ch. 5" or "Ch. 3".
    public var chapterRangeLabel: String? {
        guard let first = firstChapterTitle else { return nil }
        guard let last = lastChapterTitle, last != first else { return first }
        return "\(first) – \(last)"
    }
}
