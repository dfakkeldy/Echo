// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
import Foundation
@testable import Echo

@MainActor
struct SettingsManagerMiniPlayerTests {
    @Test func defaultsToSkipPlaySkip() {
        #expect(SettingsManager.Defaults.miniPlayerPage == [.skipBackward, .playPause, .skipForward])
    }

    @Test func encodedPageRoundTripsThroughDefaults() throws {
        let suiteName = "miniplayer-test-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let encoded = try JSONEncoder().encode([WatchAction.bookmark, .playPause, .nextTrack])
        defaults.set(encoded, forKey: "miniPlayerPage")
        let decoded = try JSONDecoder().decode(
            [WatchAction].self,
            from: try #require(defaults.data(forKey: "miniPlayerPage"))
        )
        #expect(decoded == [.bookmark, .playPause, .nextTrack])
    }
}
