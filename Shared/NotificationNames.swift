import Foundation

extension Notification.Name {
    /// Posted when transcript data has been updated (new transcription completed or loaded).
    static let transcriptDidUpdate = Notification.Name("TranscriptDidUpdate")

    /// Posted when new timeline items have been ingested (e.g., after EPUB auto-import or manual import).
    static let timelineItemsIngested = Notification.Name("TimelineItemsIngested")
}
