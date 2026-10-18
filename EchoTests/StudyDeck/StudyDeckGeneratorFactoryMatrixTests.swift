// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

@testable import Echo

nonisolated final class StudyDeckGeneratorFactoryMatrixTests: XCTestCase {
    private struct CloudSentinel: StudyDeckGenerating {
        func generate(
            sources: [StudyDeckSource],
            settings: StudyDeckGenerationSettings
        ) async -> GeneratedStudyDeckDraft {
            GeneratedStudyDeckDraft(cards: [], validSourceBlockIDs: [])
        }
    }

    private func make(
        _ preference: StudyDeckGeneratorPreference,
        cloud: Bool,
        fm: Bool
    ) -> (any StudyDeckGenerating)? {
        let cloudBuilder: (@Sendable () -> any StudyDeckGenerating)?
        if cloud {
            cloudBuilder = { CloudSentinel() }
        } else {
            cloudBuilder = nil
        }
        return StudyDeckGeneratorFactory.makeForUI(
            preference: preference,
            fmAvailable: fm,
            cloud: cloudBuilder
        )
    }

    func testAutoConfiguredCloudWins() {
        XCTAssertTrue(make(.auto, cloud: true, fm: true) is CloudSentinel)
    }

    func testAutoNoCloudFmAvailableUsesOnDeviceNeverFixture() {
        let generator = make(.auto, cloud: false, fm: true)
        XCTAssertFalse(generator is CloudSentinel)
        XCTAssertFalse(generator is FixtureStudyDeckGenerator)
    }

    func testAutoNoCloudNoFmIsExplicitlyNil() {
        XCTAssertNil(make(.auto, cloud: false, fm: false))
    }

    func testCloudPreferenceWithoutProviderIsNilNotFixture() {
        XCTAssertNil(make(.cloud, cloud: false, fm: true))
    }

    func testCloudPreferenceUsesCloud() {
        XCTAssertTrue(make(.cloud, cloud: true, fm: false) is CloudSentinel)
    }

    func testOnDeviceWithoutFmIsNilEvenWithCloudConfigured() {
        XCTAssertNil(make(.onDevice, cloud: true, fm: false))
    }
}
