// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Echo

struct MacPlaybackResumeStateTests {
    @Test func matchesSavedTrackByURLBeforeIndex() throws {
        let tracks = [
            URL(fileURLWithPath: "/Books/Dune/01.mp3"),
            URL(fileURLWithPath: "/Books/Dune/02.mp3"),
        ]
        let state = MacPlaybackResumeState(
            audiobookID: "file:///Books/Dune/",
            trackURL: tracks[1].absoluteString,
            trackIndex: 0,
            position: 123,
            updatedAt: Date(timeIntervalSince1970: 1_750_000_000)
        )

        #expect(
            state.matchingTrackIndex(
                in: tracks,
                audiobookID: "file:///Books/Dune/"
            ) == 1
        )
    }

    @Test func refusesDifferentAudiobookID() throws {
        let track = URL(fileURLWithPath: "/Books/Dune/01.mp3")
        let state = MacPlaybackResumeState(
            audiobookID: "file:///Books/Dune/",
            trackURL: track.absoluteString,
            trackIndex: 0,
            position: 123,
            updatedAt: Date(timeIntervalSince1970: 1_750_000_000)
        )

        #expect(
            state.matchingTrackIndex(
                in: [track],
                audiobookID: "file:///Books/Foundation/"
            ) == nil
        )
    }

    @Test func clampsResumePositionToKnownDuration() {
        let state = MacPlaybackResumeState(
            audiobookID: "book",
            trackURL: "file:///Books/Dune/01.mp3",
            trackIndex: 0,
            position: 400,
            updatedAt: Date(timeIntervalSince1970: 1_750_000_000)
        )

        #expect(state.clampedPosition(duration: 300) == 300)
        #expect(state.clampedPosition(duration: nil) == 400)
    }

    @Test func persistsRoundTripInDefaults() throws {
        let suiteName = "mac-resume-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let state = MacPlaybackResumeState(
            audiobookID: "book",
            trackURL: "file:///Books/Dune/01.mp3",
            trackIndex: 0,
            position: 42,
            updatedAt: Date(timeIntervalSince1970: 1_750_000_000)
        )

        state.save(to: defaults)

        #expect(MacPlaybackResumeState.load(from: defaults) == state)
    }
}
