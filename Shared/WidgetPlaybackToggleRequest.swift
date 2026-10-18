// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

// MARK: - Widget Play/Pause Handshake

/// Handshake between the widget's `TogglePlaybackIntent` and the watch app.
///
/// The widget extension cannot reach the phone: it has no `WCSession`, so a
/// play/pause intent that only flips the app group's `isPlaying` flag changes
/// the *card* without changing *playback* — the two drift apart on the first
/// tap. Instead the intent records the state the user asked for and opens the
/// app (`openAppWhenRun`); the app consumes the request on wake and sends the
/// real transport command to the phone.
///
/// The request stores the *desired absolute state*, not "toggle": an absolute
/// "play"/"pause" is idempotent, so it stays correct even if an authoritative
/// state push lands between the tap and consumption (a relative toggle would
/// double-flip). Requests expire after `freshnessWindow` — acting on a
/// minutes-old tap the app never saw would fight the user.
///
/// `nonisolated` (like `WidgetPlaybackStateStore`): pure value logic over an
/// injected `UserDefaults`, compiled into every `Shared` target.
nonisolated enum WidgetPlaybackToggleRequest {
    enum Key {
        static let desiredIsPlaying = "pendingWidgetToggleDesiredIsPlaying"
        static let requestDate = "pendingWidgetToggleDate"
    }

    /// How long a recorded tap stays actionable.
    static let freshnessWindow: TimeInterval = 30

    /// Records the state the user asked the card to reach.
    static func write(desiredIsPlaying: Bool, at date: Date, to defaults: UserDefaults) {
        defaults.set(desiredIsPlaying, forKey: Key.desiredIsPlaying)
        defaults.set(date.timeIntervalSinceReferenceDate, forKey: Key.requestDate)
    }

    /// Removes any recorded request and returns the desired state when the
    /// request is still fresh at `date`, else `nil`. Always clears: a stale
    /// request must not fire on some later wake.
    static func consume(from defaults: UserDefaults, at date: Date) -> Bool? {
        defer {
            defaults.removeObject(forKey: Key.desiredIsPlaying)
            defaults.removeObject(forKey: Key.requestDate)
        }
        guard let stamp = defaults.object(forKey: Key.requestDate) as? Double,
            let desired = defaults.object(forKey: Key.desiredIsPlaying) as? Bool
        else { return nil }
        let age = date.timeIntervalSinceReferenceDate - stamp
        guard age >= 0, age <= freshnessWindow else { return nil }
        return desired
    }
}
