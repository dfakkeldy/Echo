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

    @Test func layoutDataDefaultsToDefaultLayoutAndPersists() throws {
        let suiteName = "test-exp-layout-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        SettingsManager.registerDefaults(defaults: defaults, appGroupDefaults: defaults)
        let settings = SettingsManager(defaults: defaults, appGroupDefaults: defaults)

        #expect(
            ExperimentalPlayerLayout.decode(settings.experimentalPlayerLayoutData)
            == ExperimentalPlayerLayout.defaultLayout)

        var layout = ExperimentalPlayerLayout.defaultLayout
        layout.buttons[0].zone = .upperLeading
        settings.experimentalPlayerLayoutData = layout.encoded()

        let reloaded = SettingsManager(defaults: defaults, appGroupDefaults: defaults)
        #expect(ExperimentalPlayerLayout.decode(reloaded.experimentalPlayerLayoutData) == layout)
    }
}
