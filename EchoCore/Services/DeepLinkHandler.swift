// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Action produced by processing a deep link URL. PlayerModel executes these.
enum DeepLinkAction: Equatable {
    /// Start or resume playback.
    case play
    /// Seek immediately to the given time in seconds.
    case seek(TimeInterval)
    /// Seek was requested but the item isn't loaded yet — queue for later.
    case queueSeek(TimeInterval)
    /// Navigate to a specific tab selection.
    case navigate(TabSelection)
    /// Show the Help/Focus guide sheet.
    case showFocusGuide
    // MARK: Navigation destinations
    /// Navigate to settings (default page).
    case navigateToSettings
    /// Navigate to appearance settings.
    case navigateToAppearance
    /// Navigate to audio settings.
    case navigateToAudioSettings
    /// Navigate to a specific chapter by index.
    case navigateToChapter(Int)
    /// Navigate to a specific bookmark by UUID.
    case navigateToBookmark(UUID)
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
    mutating func handle(_ deepLink: PlayerDeepLink, isItemLoaded: Bool, isPlaying: Bool)
        -> DeepLinkAction?
    {
        switch deepLink.action {
        case .play(let time):
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

        case .focus:
            return .showFocusGuide

        case .read:
            return .navigate(.read)

        case .study:
            return .navigate(.read)

        case .navigateToSettings:
            return .navigateToSettings

        case .navigateToAppearance:
            return .navigateToAppearance

        case .navigateToAudioSettings:
            return .navigateToAudioSettings

        case .navigateToChapter(let index):
            return .navigateToChapter(index)

        case .navigateToBookmark(let id):
            return .navigateToBookmark(id)
        }
    }

    /// If a pending seek was queued and the item is now loaded, returns the
    /// seek action and clears the pending state.
    mutating func applyPendingSeekIfPossible(isItemLoaded: Bool) -> DeepLinkAction? {
        guard isItemLoaded, let target = pendingSeekTime else { return nil }
        pendingSeekTime = nil
        return .seek(target)
    }
}
