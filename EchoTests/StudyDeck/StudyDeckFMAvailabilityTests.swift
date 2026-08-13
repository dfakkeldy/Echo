// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

@testable import Echo

nonisolated final class StudyDeckFMAvailabilityTests: XCTestCase {
    func testAvailabilityIsADeterministicBoolWithoutCrashing() {
        let a = StudyDeckFMAvailability.isAvailable
        XCTAssertEqual(a, StudyDeckFMAvailability.isAvailable)  // stable, no crash
    }
    func testStatusMessageNonEmpty() {
        XCTAssertFalse(StudyDeckFMAvailability.statusMessage.isEmpty)
    }
}
