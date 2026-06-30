// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor @Suite struct SettingsNarrationQAClassifierTests {
    private func freshDefaults() -> UserDefaults {
        let suite = "test.narrationQAClassifier.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    @Test func defaultsToAuto() {
        let settings = SettingsManager(defaults: freshDefaults())
        #expect(settings.narrationQAClassifier == "auto")
    }

    @Test func persistsWrite() {
        let d = freshDefaults()
        let a = SettingsManager(defaults: d)
        a.narrationQAClassifier = "deterministic"
        let b = SettingsManager(defaults: d)
        #expect(b.narrationQAClassifier == "deterministic")
    }
}
