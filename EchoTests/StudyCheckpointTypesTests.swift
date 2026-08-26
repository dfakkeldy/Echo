// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
struct StudyCheckpointTypesTests {
    @Test func timeoutBehaviorRawValuesAreStable() {
        #expect(CheckpointTimeoutBehavior.replay.rawValue == "replay")
        #expect(CheckpointTimeoutBehavior.gradeAndAdvance.rawValue == "grade_and_advance")
        #expect(CheckpointTimeoutBehavior.wait.rawValue == "wait")
    }

    @Test func snappedTimeoutPicksNearestAllowedValue() {
        #expect(StudyCheckpointSettings.snappedTimeoutSeconds(10) == 10)
        #expect(StudyCheckpointSettings.snappedTimeoutSeconds(29) == 30)
        #expect(StudyCheckpointSettings.snappedTimeoutSeconds(60) == 60)
        #expect(StudyCheckpointSettings.snappedTimeoutSeconds(200) == 120)
        #expect(StudyCheckpointSettings.snappedTimeoutSeconds(0) == 10)
    }

    @Test func playableItemIdentityIsTheFlashcardID() {
        let item = StudyPlayableItem(
            flashcardID: "card-1", audiobookID: "book-a", chapterIndex: 0,
            planItemID: "item-1", title: "Chapter 1", startTime: 0, endTime: 100)
        #expect(item.id == "card-1")
    }

    @Test func eventTypeStringsAreStable() {
        #expect(StudyCheckpointEventType.chapterSkipped == "study_chapter_skipped")
        #expect(StudyCheckpointEventType.needsAttention == "study_item_needs_attention")
    }
}
