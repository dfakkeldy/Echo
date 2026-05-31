import Foundation
import MediaPlayer

/// Manages MPNowPlayingInfoCenter metadata updates and MPRemoteCommandCenter
/// handler registration. Does not decide *when* to update — PlayerModel drives
/// the timing and provides the data.
final class NowPlayingController {
    private var didConfigureRemoteCommands = false
    private var remoteCommandTokens: [Any] = []

    deinit {
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
            }
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
        var artworkImage: UIImage?
        var isPaused: Bool = false
        var playbackRate: Float = 1.0
    }

    /// Updates the MPNowPlayingInfoCenter with the given parameters.
    func updateNowPlayingInfo(_ params: NowPlayingParams) {
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]

        if let chapterIdx = params.chapterIndex,
           let chapterElapsed = params.chapterElapsed,
           let chapterDuration = params.chapterDuration {
            info[MPMediaItemPropertyTitle] = params.subtitle.isEmpty ? "Chapter \(chapterIdx + 1)" : params.subtitle
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
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
        }

        info[MPNowPlayingInfoPropertyPlaybackRate] = params.isPaused ? 0.0 : params.playbackRate

        if let chapterIdx = params.chapterIndex {
            info[MPNowPlayingInfoPropertyChapterNumber] = chapterIdx + 1
        }
        if params.duration.isFinite, params.duration > 0 {
            info[MPNowPlayingInfoPropertyPlaybackProgress] = params.duration > 0
                ? min(1, max(0, params.elapsed / params.duration)) : 0
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Updates only the elapsed time in the current Now Playing info, preserving
    /// all other metadata. Call this at the audio engine's tick rate.
    func updateElapsedTime(_ elapsed: TimeInterval, chapterStartOffset: TimeInterval?) {
        guard elapsed.isFinite else { return }
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
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
