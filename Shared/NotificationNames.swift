// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension Notification.Name {
    /// Posted when transcript data has been updated (new transcription completed or loaded).
    static let transcriptDidUpdate = Notification.Name("TranscriptDidUpdate")

    /// Posted when new timeline items have been ingested (e.g., after EPUB auto-import or manual import).
    static let timelineItemsIngested = Notification.Name("TimelineItemsIngested")

    /// Posted after a study plan is created or its settings/items change.
    static let studyPlanDidChange = Notification.Name("StudyPlanDidChange")

    /// Posted after the daily study queue or review counts change.
    static let studyQueueDidChange = Notification.Name("StudyQueueDidChange")
}
