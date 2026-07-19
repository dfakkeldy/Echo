// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct ExperimentalPlayerLayoutTests {

    @Test func defaultLayoutHasCoreTransportAndFiveButtons() {
        let layout = ExperimentalPlayerLayout.defaultLayout
        #expect(layout.buttons.count == 5)
        #expect(layout.buttons.contains { $0.action == .playPause && $0.zone == .lowerCenter })
        #expect(layout.buttons.contains { $0.action == .skipBackward && $0.zone == .lowerLeading })
        #expect(layout.buttons.contains { $0.action == .skipForward && $0.zone == .lowerTrailing })
    }

    @Test func codecRoundTrips() {
        let layout = ExperimentalPlayerLayout.defaultLayout
        let decoded = ExperimentalPlayerLayout.decode(layout.encoded())
        #expect(decoded == layout)
    }

    @Test func garbageDataFallsBackToDefault() {
        let decoded = ExperimentalPlayerLayout.decode(Data("not json".utf8))
        #expect(decoded == ExperimentalPlayerLayout.defaultLayout)
    }

    @Test func emptyDataFallsBackToDefault() {
        #expect(ExperimentalPlayerLayout.decode(Data()) == ExperimentalPlayerLayout.defaultLayout)
    }
}
