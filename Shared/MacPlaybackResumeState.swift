// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

nonisolated struct MacPlaybackResumeState: Codable, Equatable {
    static let storageKey = "mac.playbackResume.v1"

    var audiobookID: String
    var trackURL: String
    var trackIndex: Int
    var position: TimeInterval
    var updatedAt: Date

    func matchingTrackIndex(in tracks: [URL], audiobookID currentAudiobookID: String?) -> Int? {
        if let currentAudiobookID, currentAudiobookID != audiobookID {
            return nil
        }

        if let exact = tracks.firstIndex(where: { $0.absoluteString == trackURL }) {
            return exact
        }

        guard tracks.indices.contains(trackIndex) else { return nil }
        return trackIndex
    }

    func matches(audiobookID currentAudiobookID: String?, trackURL currentTrackURL: URL) -> Bool {
        guard currentTrackURL.absoluteString == trackURL else { return false }
        guard let currentAudiobookID else { return true }
        return currentAudiobookID == audiobookID || currentTrackURL.absoluteString == trackURL
    }

    func clampedPosition(duration: TimeInterval?) -> TimeInterval {
        let lowerBounded = max(0, position)
        guard let duration, duration.isFinite, duration > 0 else {
            return lowerBounded
        }
        return min(lowerBounded, duration)
    }

    func save(to defaults: UserDefaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    static func load(from defaults: UserDefaults) -> MacPlaybackResumeState? {
        guard let data = defaults.data(forKey: Self.storageKey) else { return nil }
        return try? JSONDecoder().decode(MacPlaybackResumeState.self, from: data)
    }
}
