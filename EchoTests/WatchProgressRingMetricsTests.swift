// SPDX-License-Identifier: GPL-3.0-or-later
import CoreFoundation
import Testing

@testable import Echo

@Suite struct WatchProgressRingMetricsTests {
    @Test("Pomodoro rings use the approved proportional weights")
    func pomodoroRingWidths() {
        #expect(WatchProgressRingMetrics.pomodoroLineWidth(hasSeparateRing: false) == 5)
        #expect(WatchProgressRingMetrics.pomodoroLineWidth(hasSeparateRing: true) == 6)
    }

    @Test("The complication geometry stays bold and safely inset")
    func complicationGeometry() {
        #expect(WatchProgressRingMetrics.complicationLineWidth == 6)
        #expect(WatchProgressRingMetrics.complicationMarkerDiameter == 8)
        #expect(WatchProgressRingMetrics.complicationInset == 4)
        #expect(WatchProgressRingMetrics.complicationArtworkPadding == 8)
        #expect(WatchProgressRingMetrics.rectangularGaugeHeight == 5)
    }
}
