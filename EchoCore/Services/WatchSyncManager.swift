import WatchConnectivity
import Foundation
import os.log

/// Manages bidirectional WatchConnectivity communication with the Apple Watch companion.
///
/// Uses closure-based callbacks rather than a delegate protocol so PlayerModel can wire
/// everything up in one `init()` block with weak-captured self.
///
/// The WatchSyncManager itself conforms to WCSessionDelegate and owns no domain knowledge
/// of audiobook playback, chapters, or bookmarks.
final class WatchSyncManager: NSObject, WCSessionDelegate {
    // MARK: - Callback Closures

    /// Called when a *live* message is received from the Watch (sendMessage).
    /// Parameters: message dict, optional reply handler.
    var onMessage: (([String: Any], (([String: Any]) -> Void)?) -> Void)?

    /// Called when a payload arrives via the persistent background queue
    /// (`transferUserInfo`). Kept separate from `onMessage` because queued payloads
    /// can be stale — the router applies stricter filtering to them.
    var onQueuedMessage: (([String: Any]) -> Void)?

    /// Called when a file (voice memo) is received from the Watch.
    var onReceiveFile: ((WCSessionFile) -> Void)?

    /// Called when the Watch sends application context (e.g. on app launch).
    var onReceiveApplicationContext: (([String: Any]) -> Void)?

    /// Returns the current state dictionary to send to the Watch.
    var stateProvider: (() -> [String: Any])?

    /// Returns (artworkKey, thumbnailData) for thumbnail transfer. Thumbnails are
    /// sent only when the active artwork changes (optimization: avoid sending
    /// heavy image data on every sync).
    var thumbnailProvider: (() -> (artworkKey: String?, data: Data?))?

    // MARK: - Private State

    private var lastSyncedArtworkKey: String?

    // MARK: - Init

    override init() {
        super.init()
        setup()
    }

    private func setup() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    // MARK: - Public API

    /// Distinguishes durable state changes from ephemeral progress ticks.
    ///
    /// `.significant` changes (book/track switch, transport, speed, loop, sleep
    /// timer, settings) are written to `updateApplicationContext` — the durable,
    /// latest-wins channel the system guarantees to deliver on the watch's next
    /// activation (and immediately if it is already active). `.progress` ticks
    /// are ephemeral: the watch interpolates position with its own timer, so
    /// they are sent live-only and never churn the application context.
    enum SyncReason {
        case significant
        case progress
    }

    /// Pushes the current playback state to the Watch app.
    ///
    /// Significant changes always refresh the durable application context, so the
    /// watch converges even if the live `sendMessage` is dropped (it is
    /// best-effort and foreground-only) or the watch app is backgrounded. The
    /// live send is kept purely as a low-latency optimisation when reachable.
    func syncToWatch(reason: SyncReason = .significant) {
        let session = WCSession.default
        guard session.activationState == .activated, let context = stateProvider?() else { return }

        // Durable channel: guarantees convergence regardless of reachability or
        // watch app state. The system coalesces to the most recent context.
        // Deliberately NOT transferUserInfo — that FIFO queue replays stale
        // snapshots (the same hazard the watch warns about for commands).
        if reason == .significant {
            #if DEBUG
            assertExpectedKeys(in: context)
            #endif
            do {
                try session.updateApplicationContext(context)
            } catch {
                os_log(.error, "updateApplicationContext failed: %{private}@", error.localizedDescription)
            }
        }

        // Live channel: low-latency push while the watch app is reachable. If it
        // is dropped, the application context above still carries the change.
        if session.isReachable {
            session.sendMessage(context, replyHandler: { _ in }) { error in
                os_log(.error, "Live watch sync dropped (context still carries it): %{private}@", error.localizedDescription)
            }
        }

        sendThumbnailIfNeeded()
    }

    private func sendThumbnailIfNeeded() {
        let session = WCSession.default
        guard session.activationState == .activated,
              let (artworkKey, data) = thumbnailProvider?(),
              let artworkKey, let data,
              artworkKey != lastSyncedArtworkKey
        else { return }

        lastSyncedArtworkKey = artworkKey
        let payload: [String: Any] = [
            "artworkKey": artworkKey,
            "thumbnailData": data
        ]
        // Since thumbnail is large, transferUserInfo is still appropriate here
        // as updateApplicationContext overwrites and we don't want to lose the
        // main state payload. But we can merge it into a single context if we want.
        // For now, leave it as transferUserInfo to not disrupt main context.
        session.transferUserInfo(payload)
    }

    // MARK: - WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        guard activationState == .activated else {
            if let error {
                os_log(.error, "WatchConnectivity activation failed: %{private}@", error.localizedDescription)
            }
            return
        }
        Task { @MainActor [weak self] in
            self?.syncToWatch()
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor [weak self] in
            self?.onMessage?(message, nil)
        }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        Task { @MainActor [weak self] in
            self?.onMessage?(message, replyHandler)
        }
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor [weak self] in
            self?.onQueuedMessage?(userInfo)
        }
    }

    func session(_ session: WCSession, didReceive file: WCSessionFile) {
        Task { @MainActor [weak self] in
            self?.onReceiveFile?(file)
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor [weak self] in
            self?.onReceiveApplicationContext?(applicationContext)
        }
    }

    #if DEBUG
    /// Expected keys in every significant application-context dictionary sent to
    /// the watch. If a key is missing, the assertion fires so developers catch
    /// context drift at the source instead of debugging stale watch UIs.
    private let expectedContextKeys: Set<String> = [
        "isPlaying", "progressFraction", "currentTime", "bookmarkStorageKey",
        "folderKey", "title", "crownAction", "isHapticFeedbackEnabled",
        "watchQuickBookmarkTimeoutSeconds", "loopMode", "playbackSpeed",
        "seekBackwardDuration", "seekForwardDuration",
        "watchPage1", "watchPage2", "watchPage3", "watchPage4", "watchPage5",
        "linearBarMode", "linearBarHidden", "circularRingMode",
        "circularRingHidden", "watchArtworkLayout", "watchBackgroundStyle",
        "watchTitleScrollEnabled",
    ]

    private func assertExpectedKeys(in context: [String: Any]) {
        let missing = expectedContextKeys.subtracting(context.keys)
        assert(missing.isEmpty, "Watch application context missing keys: \(missing.sorted())")
    }
    #endif
}
