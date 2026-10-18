// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct TimeFormattingTests {
    @Test func formatHMSPadsMinuteAndSecondComponents() {
        #expect(formatHMS(5) == "00:05")
        #expect(formatHMS(65) == "01:05")
        #expect(formatHMS(3_665) == "1:01:05")
    }

    @Test func formatHMSHandlesInvalidAndNegativeValues() {
        #expect(formatHMS(.nan) == "--:--")
        #expect(formatHMS(.infinity) == "--:--")
        #expect(formatHMS(-12) == "00:00")
    }
}
