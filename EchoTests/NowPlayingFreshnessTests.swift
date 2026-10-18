// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

struct NowPlayingFreshnessTests {
    @Test func playbackTicksDoNotContinuouslyRewriteNowPlayingElapsedTime() throws {
        let source = try Self.source(at: "EchoCore/ViewModels/PlayerModel.swift")
        let refreshProgress = try Self.slice(
            of: source,
            after: "playbackController.coordinator_refreshProgress =",
            until: "playbackController.coordinator_enabledBookmarks ="
        )

        #expect(
            !refreshProgress.contains("updateNowPlayingElapsedTime()"),
            "Continuous playback ticks should let MediaPlayer infer elapsed time from the last elapsed/rate pair instead of rewriting Now Playing every tick."
        )
    }

    @Test func playbackDelegateTicksDoNotContinuouslyRewriteNowPlayingElapsedTime() throws {
        let source = try Self.source(at: "EchoCore/ViewModels/PlayerModel+PlaybackControllerDelegate.swift")
        let didUpdateTime = try Self.slice(
            of: source,
            after: "func playbackController(_ controller: PlaybackController, didUpdateTime currentTime: TimeInterval)",
            until: "func playbackControllerDidPlayToEnd"
        )

        #expect(
            !didUpdateTime.contains("updateNowPlayingElapsedTime()"),
            "Audio-engine time callbacks should update app UI state only; MediaPlayer should infer continuous elapsed time from the last published elapsed/rate pair."
        )
    }

    @Test func seekCompletionRefreshesNowPlayingMetadata() throws {
        let source = try Self.source(at: "EchoCore/ViewModels/PlayerModel.swift")
        let seekCompleted = try Self.slice(
            of: source,
            after: "playbackController.coordinator_seekCompleted =",
            until: "playbackController.coordinator_persistSpeed ="
        )

        #expect(
            seekCompleted.contains("updateNowPlayingInfo(isPaused: !self.isPlaying)"),
            "Seek completion should publish a fresh elapsed/rate pair so Lock Screen and Control Center jump to the new position without relying on continuous ticks."
        )
    }

    private static func source(at relativePath: String) throws -> String {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()

        while directory.path != "/" {
            let candidate = directory
                .deletingLastPathComponent()
                .appending(path: relativePath)

            if FileManager.default.fileExists(atPath: candidate.path) {
                return try String(contentsOf: candidate, encoding: .utf8)
            }

            directory.deleteLastPathComponent()
        }

        throw CocoaError(.fileNoSuchFile)
    }

    private static func slice(of source: String, after: String, until: String) throws -> String {
        guard let startRange = source.range(of: after),
              let endRange = source[startRange.upperBound...].range(of: until)
        else {
            throw CocoaError(.fileReadCorruptFile)
        }

        return String(source[startRange.upperBound..<endRange.lowerBound])
    }
}
