// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct ReaderAlignmentTimestampTests {
    @Test func missingTimestampHidesAnchorLabel() {
        #expect(readerAlignmentTimestampString(nil) == nil)
    }

    @Test func presentTimestampFormatsAsMinuteSecond() {
        #expect(readerAlignmentTimestampString(65) == "1:05")
    }
}
