// SPDX-License-Identifier: GPL-3.0-or-later
import XCTest

@testable import Echo

nonisolated final class AICardGenerationSettingsProviderTests: XCTestCase {
    func testProviderPreferenceRoundTripsDefaultsAuto() {
        let key = "ai.cardgen.provider"
        let saved = UserDefaults.standard.string(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(AICardGenerationSettings.providerPreference, .auto)  // default
        AICardGenerationSettings.providerPreference = .onDevice
        XCTAssertEqual(AICardGenerationSettings.providerPreference, .onDevice)
    }
}
