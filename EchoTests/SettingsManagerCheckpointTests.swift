// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
struct SettingsManagerCheckpointTests {
    private func makeSettings(
        seed: (UserDefaults) -> Void = { _ in }
    ) throws -> (SettingsManager, UserDefaults, String, UserDefaults, String) {
        let suiteName = "checkpoint-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        seed(defaults)

        let appGroupSuiteName = "\(suiteName)-group"
        let appGroupDefaults = try #require(UserDefaults(suiteName: appGroupSuiteName))
        let settings = SettingsManager(
            defaults: defaults,
            appGroupDefaults: appGroupDefaults,
            defaultsDomainName: nil,
            appGroupDefaultsDomainName: nil
        )
        return (settings, defaults, suiteName, appGroupDefaults, appGroupSuiteName)
    }

    private func removeDefaults(
        _ defaults: UserDefaults,
        suiteName: String,
        _ appGroupDefaults: UserDefaults,
        appGroupSuiteName: String
    ) {
        defaults.removePersistentDomain(forName: suiteName)
        appGroupDefaults.removePersistentDomain(forName: appGroupSuiteName)
    }

    @Test func defaultsMatchTheSpec() throws {
        let (settings, defaults, suite, appGroupDefaults, appGroupSuite) = try makeSettings()
        defer {
            removeDefaults(
                defaults, suiteName: suite, appGroupDefaults, appGroupSuiteName: appGroupSuite)
        }

        #expect(settings.checkpointTimeoutSeconds == 30)
        // EchoTests builds for iOS: the platform default is Replay.
        #expect(settings.checkpointTimeoutBehavior == CheckpointTimeoutBehavior.replay.rawValue)
        #expect(settings.checkpointAutoAdvance == true)
        #expect(settings.checkpointRemoteGrading == true)
    }

    @Test func timeoutSnapsToAllowedValuesOnWrite() throws {
        let (settings, defaults, suite, appGroupDefaults, appGroupSuite) = try makeSettings()
        defer {
            removeDefaults(
                defaults, suiteName: suite, appGroupDefaults, appGroupSuiteName: appGroupSuite)
        }

        settings.checkpointTimeoutSeconds = 45
        #expect(settings.checkpointTimeoutSeconds == 30)
        #expect(defaults.integer(forKey: "checkpointTimeoutSeconds") == 30)

        settings.checkpointTimeoutSeconds = 120
        #expect(settings.checkpointTimeoutSeconds == 120)
    }

    @Test func tamperedStoredTimeoutLoadsSnapped() throws {
        let (settings, defaults, suite, appGroupDefaults, appGroupSuite) = try makeSettings {
            defaults in
            defaults.set(7, forKey: "checkpointTimeoutSeconds")
        }
        defer {
            removeDefaults(
                defaults, suiteName: suite, appGroupDefaults, appGroupSuiteName: appGroupSuite)
        }

        #expect(settings.checkpointTimeoutSeconds == 10)
    }

    @Test func togglesPersist() throws {
        let (settings, defaults, suite, appGroupDefaults, appGroupSuite) = try makeSettings()
        defer {
            removeDefaults(
                defaults, suiteName: suite, appGroupDefaults, appGroupSuiteName: appGroupSuite)
        }

        settings.checkpointAutoAdvance = false
        settings.checkpointRemoteGrading = false
        settings.checkpointTimeoutBehavior = CheckpointTimeoutBehavior.wait.rawValue

        #expect(defaults.bool(forKey: "checkpointAutoAdvance") == false)
        #expect(defaults.bool(forKey: "checkpointRemoteGrading") == false)
        #expect(defaults.string(forKey: "checkpointTimeoutBehavior") == "wait")
    }
}
