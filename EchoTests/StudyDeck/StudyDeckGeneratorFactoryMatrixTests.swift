// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

@testable import Echo

// `nonisolated`: XCTestCase subclass under Swift 6 MainActor default isolation; nonisolated so the
// init overrides match XCTestCase's nonisolated inits (pure synchronous value tests).
nonisolated final class StudyDeckGeneratorFactoryMatrixTests: XCTestCase {
    // Stand-in for the anthropic builder — lets us assert cloud-path selection by type identity.
    private struct CloudSentinel: StudyDeckGenerating {
        func generate(
            sources: [StudyDeckSource],
            settings: StudyDeckGenerationSettings
        ) async -> GeneratedStudyDeckDraft {
            GeneratedStudyDeckDraft(cards: [], validSourceBlockIDs: [])
        }
    }

    private func make(
        _ p: StudyDeckGeneratorPreference,
        key: Bool,
        fm: Bool
    ) -> any StudyDeckGenerating {
        StudyDeckGeneratorFactory.make(preference: p, hasKey: key, fmAvailable: fm) {
            CloudSentinel()
        }
    }

    // MARK: - Matrix tests

    func testAutoKeyWins() {
        XCTAssertTrue(make(.auto, key: true, fm: true) is CloudSentinel)
    }

    // Tolerant: fmAvailable=true resolves to FM generator when iOS 26 SDK is available,
    // or falls back to fixture on an older sim. Must never be CloudSentinel.
    func testAutoNoKeyFmAvailableUsesOnDevice() {
        let g = make(.auto, key: false, fm: true)
        XCTAssertFalse(g is CloudSentinel)
    }

    func testAutoNoKeyNoFmUsesFixture() {
        XCTAssertTrue(make(.auto, key: false, fm: false) is FixtureStudyDeckGenerator)
    }

    func testCloudNoKeyFixture() {
        XCTAssertTrue(make(.cloud, key: false, fm: true) is FixtureStudyDeckGenerator)
    }

    func testOnDeviceNoFmFixture() {
        XCTAssertTrue(make(.onDevice, key: true, fm: false) is FixtureStudyDeckGenerator)
    }

    func testCloudWithKeyUsesCloud() {
        XCTAssertTrue(make(.cloud, key: true, fm: false) is CloudSentinel)
    }
}
