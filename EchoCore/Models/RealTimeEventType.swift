import Foundation

/// The category of a real-time activity event recorded for stats / daily-review.
///
/// Persisted as the `event_type` raw string on `RealTimeEventRecord`
/// (see Schema_V14). Kept as a standalone enum after the legacy Timeline-feed
/// `RealTimeEvent` view-model struct was removed — the raw value is the stable
/// on-disk contract consumed by `PlaybackEventLogger`, `PlayerModel+PlaybackLogging`,
/// and `DailyReviewViewModel`.
enum RealTimeEventType: String, Codable, CaseIterable, Sendable {
    case playbackSession = "playback_session"
    case bookmarkCreated = "bookmark_created"
    case flashcardReviewed = "flashcard_reviewed"
    case voiceMemoRecorded = "voice_memo_recorded"
    case noteCreated = "note_created"
    case plannedSessionCompleted = "planned_session_completed"
    case chapterTransition = "chapter_transition"
}
