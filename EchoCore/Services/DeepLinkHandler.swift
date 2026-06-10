import Foundation

/// Action produced by processing a deep link URL. PlayerModel executes these.
enum DeepLinkAction: Equatable {
    /// Start or resume playback.
    case play
    /// Seek immediately to the given time in seconds.
    case seek(TimeInterval)
    /// Seek was requested but the item isn't loaded yet — queue for later.
    case queueSeek(TimeInterval)
}

/// Parses and processes `echoaudio://` deep link URLs, managing a pending
/// seek queue for deep links that arrive before the audiobook is loaded.
struct DeepLinkHandler {

    /// A seek time that could not be applied immediately because no item was
    /// loaded. PlayerModel should call `applyPendingSeekIfPossible()` once
    /// a track becomes ready.
    private(set) var pendingSeekTime: TimeInterval?

    /// Processes a parsed deep link and returns the action PlayerModel should
    /// take. May update internal pending-seek state.
    /// - Parameters:
    ///   - deepLink: The parsed deep link model.
    ///   - isItemLoaded: Whether an audiobook track is currently loaded.
    ///   - isPlaying: Whether playback is currently active.
    mutating func handle(_ deepLink: PlayerDeepLink, isItemLoaded: Bool, isPlaying: Bool) -> DeepLinkAction? {
        let time = deepLink.time
        var action: DeepLinkAction?

        if let time {
            if isItemLoaded {
                action = .seek(time)
            } else {
                pendingSeekTime = time
                action = .queueSeek(time)
            }
        }

        if isItemLoaded, !isPlaying {
            if action != nil {
                return action
            }
            return .play
        }

        return action
    }

    /// If a pending seek was queued and the item is now loaded, returns the
    /// seek action and clears the pending state.
    mutating func applyPendingSeekIfPossible(isItemLoaded: Bool) -> DeepLinkAction? {
        guard isItemLoaded, let target = pendingSeekTime else { return nil }
        pendingSeekTime = nil
        return .seek(target)
    }
}
