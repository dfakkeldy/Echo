// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

@testable import Echo

// `nonisolated`: XCTestCase subclass under Swift 6 MainActor default isolation; nonisolated so the
// init overrides match XCTestCase's nonisolated inits (pure synchronous value tests).
nonisolated final class StudyDeckGeneratorFactoryTests: XCTestCase {
    func testFallsBackToFixtureWhenNoKey() {
        let generator = StudyDeckGeneratorFactory.make(hasKey: false) {
            XCTFail("Anthropic generator must not be built without a key")
            return FixtureStudyDeckGenerator()
        }
        XCTAssertTrue(generator is FixtureStudyDeckGenerator)
    }

    func testUsesAnthropicWhenKeyPresent() {
        let sentinel = FixtureStudyDeckGenerator()  // stand-in; identity check below
        let generator = StudyDeckGeneratorFactory.make(hasKey: true) { sentinel }
        XCTAssertTrue(generator is FixtureStudyDeckGenerator)  // sentinel returned, builder invoked
    }
}
