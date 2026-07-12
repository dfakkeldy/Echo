// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum WatchStateDeliverySource: Equatable {
    case applicationContext
    case liveMessage
    case queuedUserInfo
}

/// Orders complete phone snapshots while preserving the separate thumbnail-only
/// `transferUserInfo` channel. Queued deliveries never carry complete state,
/// even before a modern stamped snapshot has arrived.
struct WatchStateRecencyPolicy {
    static let persistedSequenceKey = "lastAppliedWatchStateSequence"
    static let persistedArtworkSequenceKey = "lastAppliedWatchArtworkSequence"
    static let persistedThumbnailSequenceKey = "lastAppliedWatchThumbnailSequence"

    private static let legacyThumbnailKeys: Set<String> = [
        "artworkKey", "thumbnailData",
    ]
    private static let orderedThumbnailKeys: Set<String> = [
        "artworkSeq", "artworkKey", "thumbnailData",
    ]

    private(set) var lastAppliedSequence: Double?
    private(set) var latestArtworkSequence: Double?
    private(set) var lastAppliedThumbnailSequence: Double?

    init(
        lastAppliedSequence: Double? = nil,
        latestArtworkSequence: Double? = nil,
        lastAppliedThumbnailSequence: Double? = nil
    ) {
        self.lastAppliedSequence = Self.validSequence(lastAppliedSequence)
        self.latestArtworkSequence = Self.validSequence(latestArtworkSequence)
        self.lastAppliedThumbnailSequence = Self.validSequence(lastAppliedThumbnailSequence)
    }

    mutating func shouldApply(
        _ state: [String: Any], source: WatchStateDeliverySource
    ) -> Bool {
        if source == .queuedUserInfo {
            return shouldApplyThumbnail(state)
        }

        guard let sequence = Self.sequence(in: state, key: "stateSeq") else {
            // Compatibility with an older phone that has never sent stamped state.
            return lastAppliedSequence == nil && latestArtworkSequence == nil
        }
        if let lastAppliedSequence, sequence <= lastAppliedSequence { return false }
        if let latestArtworkSequence, sequence < latestArtworkSequence { return false }

        if state["artworkSeq"] != nil {
            guard let artworkSequence = Self.sequence(in: state, key: "artworkSeq") else {
                return false
            }
            guard artworkSequence <= sequence else { return false }
            if let latestArtworkSequence, artworkSequence < latestArtworkSequence {
                return false
            }
            latestArtworkSequence = artworkSequence
        }

        lastAppliedSequence = sequence
        return true
    }

    private mutating func shouldApplyThumbnail(_ state: [String: Any]) -> Bool {
        let keys = Set(state.keys)
        guard state["artworkKey"] is String, state["thumbnailData"] is Data else {
            return false
        }

        if keys == Self.legacyThumbnailKeys {
            return lastAppliedSequence == nil && latestArtworkSequence == nil
        }

        guard keys == Self.orderedThumbnailKeys,
            let artworkSequence = Self.sequence(in: state, key: "artworkSeq")
        else { return false }
        if let latestArtworkSequence, artworkSequence < latestArtworkSequence { return false }
        if let lastAppliedThumbnailSequence,
            artworkSequence <= lastAppliedThumbnailSequence
        {
            return false
        }

        latestArtworkSequence = artworkSequence
        lastAppliedThumbnailSequence = artworkSequence
        return true
    }

    private static func sequence(in state: [String: Any], key: String) -> Double? {
        validSequence((state[key] as? NSNumber)?.doubleValue)
    }

    private static func validSequence(_ sequence: Double?) -> Double? {
        guard let sequence, sequence.isFinite, sequence > 0 else { return nil }
        return sequence
    }
}

enum WatchWidgetReloadPolicy {
    static func shouldReload(
        state: [String: Any],
        currentIsPlaying: Bool,
        currentTrackId: String?,
        currentAccentHex: String?,
        hasCachedThumbnail: Bool
    ) -> Bool {
        let incomingAccent = (state["artworkAccentColorHex"] as? String).flatMap {
            $0.isEmpty ? nil : $0
        }

        return ((state["isPlaying"] as? Bool).map { $0 != currentIsPlaying } ?? false)
            || ((state["trackId"] as? String).map { $0 != currentTrackId } ?? false)
            || (state["artworkAccentColorHex"] != nil && incomingAccent != currentAccentHex)
            || state["thumbnailData"] != nil
            || (state["hasThumbnail"] as? Bool == false && hasCachedThumbnail)
    }
}
