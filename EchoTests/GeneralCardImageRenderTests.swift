// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

struct GeneralCardImageRenderTests {
    @Test func decodesImagePathFromMediaJSON() {
        let json = #"{"imagePath":"/tmp/fig.png"}"#
        #expect(StudyCardMedia.imagePath(fromMediaJSON: json) == "/tmp/fig.png")
    }

    @Test func returnsNilForAbsentOrMalformedMediaJSON() {
        #expect(StudyCardMedia.imagePath(fromMediaJSON: nil) == nil)
        #expect(StudyCardMedia.imagePath(fromMediaJSON: "not json") == nil)
        #expect(StudyCardMedia.imagePath(fromMediaJSON: #"{"retirePromptShownAt":"x"}"#) == nil)
    }
}
