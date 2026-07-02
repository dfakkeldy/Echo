// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// What happens when the checkpoint countdown expires without a tap.
enum CheckpointTimeoutBehavior: String, Codable, Sendable, CaseIterable {
    /// Grade `.again` automatically and replay the chapter (iOS default).
    case replay
    /// Grade `.again` automatically and advance to the next queue item.
    case gradeAndAdvance = "grade_and_advance"
    /// Record no grade; the chapter stays due today and resurfaces in the queue.
    case wait
}

/// Snapshot of the checkpoint settings, read through a provider closure so the
/// coordinator always sees current values without owning SettingsManager.
struct StudyCheckpointSettings: Equatable, Sendable {
    /// Allowed countdown durations, in seconds. Settings UI offers exactly these.
    static let allowedTimeoutSeconds = [10, 30, 60, 120]

    var timeoutSeconds: Int
    var timeoutBehavior: CheckpointTimeoutBehavior
    var autoAdvance: Bool
    var remoteGrading: Bool
    /// Mirrors `SettingsManager.studyGlobalNewChapterLimit` for queue builds.
    var globalNewChapterLimit: Int? = nil

    /// Snaps an arbitrary stored value to the nearest allowed duration.
    static func snappedTimeoutSeconds(_ value: Int) -> Int {
        allowedTimeoutSeconds.min { abs($0 - value) < abs($1 - value) } ?? 30
    }
}

/// One playable unit of today's study queue: a chapter listening assignment
/// materialized as (book identity, chapter audio range, flashcard).
struct StudyPlayableItem: Identifiable, Equatable, Sendable {
    /// Stable across queue rebuilds: the assignment flashcard's id.
    var id: String { flashcardID }
    let flashcardID: String
    let audiobookID: String
    let chapterIndex: Int?
    /// The `study_plan_item` id, when the queue entry carried one.
    let planItemID: String?
    let title: String
    let startTime: TimeInterval
    let endTime: TimeInterval?
}

/// `real_time_event.event_type` values written by the checkpoint/queue layer.
enum StudyCheckpointEventType {
    nonisolated static let chapterSkipped = "study_chapter_skipped"
    nonisolated static let needsAttention = "study_item_needs_attention"
}
