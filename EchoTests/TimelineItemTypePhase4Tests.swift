// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct TimelineItemTypePhase4Tests {
    @Test func newCasesHaveStableRawValues() {
        #expect(TimelineItemType.voiceMemo.rawValue == "voiceMemo")
        #expect(TimelineItemType.note.rawValue == "note")
    }

    @Test func roundTripsThroughRawValue() {
        #expect(TimelineItemType(rawValue: "voiceMemo") == .voiceMemo)
        #expect(TimelineItemType(rawValue: "note") == .note)
    }

    @Test func legacyNoteMapsToNoteNotBookmark() {
        #expect(TimelineItemType(legacyRawValue: "note") == .note)
    }

    @Test func legacyBookmarkStillMapsToBookmark() {
        #expect(TimelineItemType(legacyRawValue: "bookmark") == .bookmark)
    }
}
