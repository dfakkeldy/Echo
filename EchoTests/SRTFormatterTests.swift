// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct SRTFormatterTests {
    @Test func timestampFormatsHoursMinutesSecondsMilliseconds() {
        #expect(SRTFormatter.timestamp(0) == "00:00:00,000")
        #expect(SRTFormatter.timestamp(3723.456) == "01:02:03,456")
        #expect(SRTFormatter.timestamp(59.9999) == "00:00:59,999")  // never rounds into 60
    }

    @Test func srtDocumentNumbersAndSeparatesCues() {
        let cues = [
            SlideshowSRTCue(startTime: 0, endTime: 2.5, text: "First line."),
            SlideshowSRTCue(startTime: 2.5, endTime: 5, text: "Second line."),
        ]
        let expected = """
            1
            00:00:00,000 --> 00:00:02,500
            First line.

            2
            00:00:02,500 --> 00:00:05,000
            Second line.
            """ + "\n"
        #expect(SRTFormatter.srtDocument(cues: cues) == expected)
    }

    @Test func srtDocumentIsEmptyForNoCues() {
        #expect(SRTFormatter.srtDocument(cues: []) == "")
    }

    @Test func chaptersDocumentUsesYouTubeTimestampLines() {
        let marks = [
            SlideshowChapterMark(startTime: 0, title: "Opening"),
            SlideshowChapterMark(startTime: 3723, title: "The Middle"),
        ]
        let expected = """
            00:00:00 Opening
            01:02:03 The Middle
            """ + "\n"
        #expect(SRTFormatter.chaptersDocument(marks: marks) == expected)
    }
}
