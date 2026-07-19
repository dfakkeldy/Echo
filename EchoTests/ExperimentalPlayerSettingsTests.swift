// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
struct ExperimentalPlayerSettingsTests {

    @Test func experimentalLayoutDefaultsOffAndPersists() throws {
        let suiteName = "test-exp-player-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        SettingsManager.registerDefaults(defaults: defaults, appGroupDefaults: defaults)
        let settings = SettingsManager(defaults: defaults, appGroupDefaults: defaults)

        #expect(SettingsManager.Defaults.experimentalNowPlayingLayout == false)
        #expect(settings.experimentalNowPlayingLayout == false)

        settings.experimentalNowPlayingLayout = true

        let reloaded = SettingsManager(defaults: defaults, appGroupDefaults: defaults)
        #expect(reloaded.experimentalNowPlayingLayout == true)
    }
}
