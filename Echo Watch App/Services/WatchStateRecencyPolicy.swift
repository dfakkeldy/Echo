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

    /// Forgets the applied-thumbnail marker. Called when the cached thumbnail
    /// image is gone (cleared by an explicit absence, a track change, or a
    /// fresh install), so a re-sent transfer carrying the SAME artwork
    /// sequence is applied instead of deduplicated away. `latestArtworkSequence`
    /// deliberately survives: it orders thumbnails against state and must not
    /// regress just because the cached image was dropped.
    mutating func forgetAppliedThumbnail() {
        lastAppliedThumbnailSequence = nil
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

struct WatchWidgetScrubReloadCoordinator {
    private var outstandingCommands = 0
    private var gestureIsIdle = false
    private var recoveryRequired = false

    mutating func commandSent() {
        gestureIsIdle = false
        outstandingCommands += 1
    }

    mutating func gestureDidEnd() -> Bool {
        gestureIsIdle = true
        return consumeReloadIfReady()
    }

    mutating func commandFinished(requiresRecovery: Bool = false) -> Bool {
        if outstandingCommands > 0 {
            outstandingCommands -= 1
        }
        recoveryRequired = recoveryRequired || requiresRecovery
        return consumeReloadIfReady()
    }

    mutating func recoveryStateApplied() -> Bool {
        recoveryRequired = false
        return consumeReloadIfReady()
    }

    private mutating func consumeReloadIfReady() -> Bool {
        guard gestureIsIdle, outstandingCommands == 0, !recoveryRequired else { return false }
        gestureIsIdle = false
        return true
    }
}

enum WatchWidgetReloadPolicy {
    private static let progressDiscontinuityThreshold = 0.02

    static func shouldReload(
        state: [String: Any],
        currentIsPlaying: Bool,
        currentFolderKey: String? = nil,
        currentTrackId: String?,
        currentTitle: String? = nil,
        incomingTitle: String? = nil,
        currentPlaybackSpeed: Double? = nil,
        projectedProgressFraction: Double? = nil,
        reloadOnProgressDiscontinuity: Bool = true,
        currentBookDuration: Double? = nil,
        currentAccentHex: String?,
        currentRampTopHex: String?,
        hasCachedThumbnail: Bool
    ) -> Bool {
        let incomingAccent = (state["artworkAccentColorHex"] as? String).flatMap {
            $0.isEmpty ? nil : $0
        }
        // The ramp needs its own clause because it does NOT move with the
        // accent. The ramp follows the primary hue, but a promoted accent is
        // seeded from a different candidate entirely, so displayed bookmark
        // artwork can change the room while leaving the accent and the track
        // untouched. Only the top end is checked: both ends come out of one
        // resolve at the same hue, so they cannot move independently.
        let incomingRampTop = (state["coverRampTopHex"] as? String).flatMap {
            $0.isEmpty ? nil : $0
        }
        let hasProgressDiscontinuity: Bool = {
            guard let incoming = state["totalProgressFraction"] as? Double,
                let projectedProgressFraction,
                incoming.isFinite,
                projectedProgressFraction.isFinite
            else { return false }
            return abs(incoming - projectedProgressFraction) > progressDiscontinuityThreshold
        }()
        let hasDurationCorrection: Bool = {
            guard let incoming = state["totalBookDuration"] as? Double,
                let currentBookDuration,
                incoming.isFinite,
                currentBookDuration.isFinite
            else { return false }
            return abs(incoming - currentBookDuration) > 1
        }()

        return ((state["isPlaying"] as? Bool).map { $0 != currentIsPlaying } ?? false)
            || ((state["folderKey"] as? String).map { $0 != currentFolderKey } ?? false)
            || ((state["trackId"] as? String).map { $0 != currentTrackId } ?? false)
            || (incomingTitle.map { $0 != currentTitle } ?? false)
            || ((state["playbackSpeed"] as? Double).map { $0 != currentPlaybackSpeed } ?? false)
            || (reloadOnProgressDiscontinuity && hasProgressDiscontinuity)
            || hasDurationCorrection
            || (state["artworkAccentColorHex"] != nil && incomingAccent != currentAccentHex)
            || (state["coverRampTopHex"] != nil && incomingRampTop != currentRampTopHex)
            || state["thumbnailData"] != nil
            || (state["hasThumbnail"] as? Bool == false && hasCachedThumbnail)
    }
}
