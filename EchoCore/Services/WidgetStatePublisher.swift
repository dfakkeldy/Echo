// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

#if canImport(WidgetKit)
    import WidgetKit
#endif

/// Mirrors the live playback snapshot into the shared App Group so the iOS
/// home-screen widget (`Echo_Widget`) and the Control Center toggle
/// (`Echo_WidgetControl`) reflect the app's real play/pause state, title, and
/// progress.
///
/// Why this exists: the watch stays in sync over WatchConnectivity, and the Lock
/// Screen over `MPNowPlayingInfoCenter` — but the iPhone widgets read
/// `AppGroupDefaults.shared`, which nothing on the app side was writing. They
/// could only ever show stale state (the value their own toggle intent last set,
/// or a one-time legacy migration), so a play/pause done in the app never reached
/// them. This publisher closes that gap on every significant playback change.
///
/// `defaults` and `reload` are injected (defaulting to the real app-group suite
/// and a WidgetKit reload) following the project's concrete-type DI seam
/// (`DatabaseService(inMemory:)`), so the write/reload contract is unit-testable
/// without the real app-group store or WidgetKit.
@MainActor
final class WidgetStatePublisher {
    private let defaults: UserDefaults
    private let reload: @MainActor () -> Void

    init(
        defaults: UserDefaults = AppGroupDefaults.shared,
        reload: @MainActor @escaping () -> Void = WidgetStatePublisher.reloadSharedWidgets
    ) {
        self.defaults = defaults
        self.reload = reload
    }

    /// Writes the keys the iOS widget surfaces actually read and reloads them.
    /// Scoped deliberately to those keys: `Echo_Widget` reads `isPlaying`,
    /// `title`, `totalProgressFraction`, `thumbnailData`; `Echo_WidgetControl`
    /// reads `isPlaying`.
    ///
    /// We do NOT mirror `currentTime` / `folderKey` / `trackId` here even though
    /// `CreateBookmarkIntent` reads them: `context["currentTime"]` is the
    /// *cumulative book* time, but that intent treats it as a *per-track* offset,
    /// so freshly writing it would create mis-placed widget/Siri bookmarks on
    /// multi-track books. Leaving those keys untouched keeps the bookmark intent
    /// at its existing (separate) baseline rather than feeding it wrong data.
    func publish(context: [String: Any], thumbnailData: Data?) {
        // `isPlaying` is the key the bug is about: always write it (defaulting to
        // paused) so a stale `true` left by the widget's own toggle intent is
        // cleared the moment the app pauses or stops.
        defaults.set(context["isPlaying"] as? Bool ?? false, forKey: "isPlaying")
        if let title = context["title"] as? String {
            defaults.set(title, forKey: "title")
        }
        if let progress = context["totalProgressFraction"] as? Double {
            defaults.set(progress, forKey: "totalProgressFraction")
        }
        // Only overwrite the thumbnail when we have fresh data — the watch sends
        // artwork on a separate, throttled channel, so a nil here means "no
        // change", not "clear the image".
        if let thumbnailData {
            defaults.set(thumbnailData, forKey: "thumbnailData")
        }
        reload()
    }

    /// Mirrors the live PER-TRACK playback position into the App Group for the
    /// "Bookmark this in Echo" Siri / App Intent, which stores a per-track
    /// `Bookmark.timestamp`. This is the per-track counterpart `publish(...)`
    /// deliberately left alone: it writes `currentTrackTime` (the offset within
    /// the current track), **not** the cumulative `currentTime` the watch context
    /// carries, so a multi-track bookmark lands in the right place.
    ///
    /// Reload-free by design, so the caller can run it on every sync (including
    /// progress ticks) to keep the position fresh without the cost of a widget
    /// reload — the displayed widget keys (above) don't depend on it. Passing
    /// `nil` clears the keys so a stale, no-longer-open book can't be bookmarked.
    func publishPlaybackPosition(_ state: WidgetPlaybackState?) {
        WidgetPlaybackStateStore.write(state, to: defaults)
    }

    /// Default reload: refresh the home-screen widget timeline and the Control
    /// Center toggle. Both are iOS-only surfaces, so the body is gated.
    static func reloadSharedWidgets() {
        #if os(iOS)
            WidgetCenter.shared.reloadTimelines(ofKind: "Echo_Widget")
            if #available(iOS 18.0, *) {
                ControlCenter.shared.reloadControls(
                    ofKind: "Dan.EchoAudiobooks.watchkitapp.Echo_Widget")
            }
        #endif
    }
}
