// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import MediaPlayer

#if canImport(UIKit)
    import UIKit

    /// The platform image type `MPMediaItemArtwork` expects — `UIImage` on UIKit
    /// platforms, `NSImage` on macOS — so the Now Playing artwork path is written
    /// once for both. (macOS showed no artwork at all while this was `#if os(iOS)`.)
    typealias PlatformImage = UIImage
#elseif canImport(AppKit)
    import AppKit

    typealias PlatformImage = NSImage
#endif

/// Manages MPNowPlayingInfoCenter metadata updates and MPRemoteCommandCenter
/// handler registration. Does not decide *when* to update — PlayerModel drives
/// the timing and provides the data.
@MainActor
final class NowPlayingController {
    private var didConfigureRemoteCommands = false
    private var remoteCommandTokens: [Any] = []

    // `isolated deinit` (SE-0371): the class is `@MainActor`, and
    // `remoteCommandTokens` is a non-Sendable `[Any]` of MPRemoteCommandCenter
    // targets. A plain nonisolated deinit cannot touch that MainActor state, so
    // run the deinit on the main actor to release the handlers safely.
    isolated deinit {
        remoteCommandTokens.removeAll()
    }

    // MARK: - Remote Commands

    /// Registers handlers for Lock Screen / Control Center / CarPlay remote
    /// commands. Safe to call multiple times — subsequent calls are no-ops.
    func configureRemoteCommands(
        play: @escaping () -> Void,
        pause: @escaping () -> Void,
        togglePlayPause: @escaping () -> Void,
        nextTrack: @escaping () -> Void,
        skipBackward: @escaping () -> Void,
        skipForward: @escaping () -> Void = {},
        previousTrack: @escaping () -> Void = {},
        seek: @escaping (TimeInterval) -> Void = { _ in },
        skipBackwardInterval: Int = 30,
        skipForwardInterval: Int = 30
    ) {
        guard !didConfigureRemoteCommands else { return }
        didConfigureRemoteCommands = true

        let center = MPRemoteCommandCenter.shared()

        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.nextTrackCommand.isEnabled = true
        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipBackwardInterval)]
        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: skipForwardInterval)]
        center.previousTrackCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true

        remoteCommandTokens = [
            center.playCommand.addTarget { _ in
                Task { @MainActor in play() }
                return .success
            },
            center.pauseCommand.addTarget { _ in
                Task { @MainActor in pause() }
                return .success
            },
            center.togglePlayPauseCommand.addTarget { _ in
                Task { @MainActor in togglePlayPause() }
                return .success
            },
            center.nextTrackCommand.addTarget { _ in
                Task { @MainActor in nextTrack() }
                return .success
            },
            center.skipBackwardCommand.addTarget { _ in
                Task { @MainActor in skipBackward() }
                return .success
            },
            center.skipForwardCommand.addTarget { _ in
                Task { @MainActor in skipForward() }
                return .success
            },
            center.previousTrackCommand.addTarget { _ in
                Task { @MainActor in previousTrack() }
                return .success
            },
            center.changePlaybackPositionCommand.addTarget { event in
                guard let evt = event as? MPChangePlaybackPositionCommandEvent else {
                    return .commandFailed
                }
                let positionTime = evt.positionTime
                Task { @MainActor in seek(positionTime) }
                return .success
            },
        ]
    }

    // MARK: - Now Playing Info

    /// Parameters for building the Now Playing info dictionary.
    struct NowPlayingParams {
        var title: String = ""
        var subtitle: String = ""
        var albumTitle: String?
        var elapsed: TimeInterval = 0
        var duration: TimeInterval = 0
        var chapterIndex: Int?
        var chapterElapsed: TimeInterval?
        var chapterDuration: TimeInterval?
        var artworkImage: PlatformImage?
        var isPaused: Bool = false
        var playbackRate: Float = 1.0
    }

    /// Updates the MPNowPlayingInfoCenter with the given parameters.
    func updateNowPlayingInfo(_ params: NowPlayingParams) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]

        if let chapterIdx = params.chapterIndex,
            let chapterElapsed = params.chapterElapsed,
            let chapterDuration = params.chapterDuration
        {
            info[MPMediaItemPropertyTitle] =
                params.subtitle.isEmpty ? "Ch \(chapterIdx + 1)" : params.subtitle
            info[MPMediaItemPropertyAlbumTitle] = params.title
            info[MPMediaItemPropertyPlaybackDuration] = chapterDuration
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = chapterElapsed
        } else {
            info[MPMediaItemPropertyTitle] = params.title
            if let albumTitle = params.albumTitle, !albumTitle.isEmpty {
                info[MPMediaItemPropertyAlbumTitle] = albumTitle
            } else {
                info.removeValue(forKey: MPMediaItemPropertyAlbumTitle)
            }
            if params.duration.isFinite, params.duration > 0 {
                info[MPMediaItemPropertyPlaybackDuration] = params.duration
            }
            if params.elapsed.isFinite {
                info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = params.elapsed
            }
        }

        if let image = params.artworkImage {
            // PlatformImage (UIImage / NSImage) is Sendable, so it's safe to capture
            // for the artwork request handler, which the system may invoke off the
            // main actor.
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in
                image
            }
        }

        info[MPNowPlayingInfoPropertyPlaybackRate] = params.isPaused ? 0.0 : params.playbackRate
        // The system uses DefaultPlaybackRate to know what "1×" means for this item.
        // Without it, Lock Screen / Control Center may show the wrong transport button
        // after a playback-rate change (e.g. speed 2× → pause → Lock Screen still shows ⏸).
        info[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0

        if let chapterIdx = params.chapterIndex {
            info[MPNowPlayingInfoPropertyChapterNumber] = chapterIdx + 1
        } else {
            // `info` is seeded from the previously-published dict, so a stale
            // chapter number would otherwise persist when switching from a
            // chaptered book to a non-chaptered one.
            info.removeValue(forKey: MPNowPlayingInfoPropertyChapterNumber)
        }
        if params.duration.isFinite, params.duration > 0 {
            info[MPNowPlayingInfoPropertyPlaybackProgress] =
                params.duration > 0
                ? min(1, max(0, params.elapsed / params.duration)) : 0
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Updates only the elapsed time in the current Now Playing info, preserving
    /// all other metadata. Call this at the audio engine's tick rate.
    /// Does NOT create a new info dictionary from scratch — that would lack
    /// the playback rate and cause the Lock Screen to show the wrong button.
    func updateElapsedTime(_ elapsed: TimeInterval, chapterStartOffset: TimeInterval?) {
        guard elapsed.isFinite else { return }
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        if let offset = chapterStartOffset {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = max(0, elapsed - offset)
        } else {
            info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = elapsed
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    // MARK: - Utilities

    static func formatTime(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 {
            return String(format: "%d:%02d:%02d", h, m, s)
        } else {
            return String(format: "%d:%02d", m, s)
        }
    }
}
