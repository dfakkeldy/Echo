// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct AlignmentAnchorTranscriptSourceTests {
    @Test func transcriptAlignmentHasStableRawValue() {
        #expect(AlignmentAnchorRecord.Source.transcriptAlignment.rawValue == "transcriptAlignment")
    }

    @Test func transcriptAlignmentRoundTripsFromRawValue() {
        #expect(
            AlignmentAnchorRecord.Source(rawValue: "transcriptAlignment") == .transcriptAlignment)
    }
}
