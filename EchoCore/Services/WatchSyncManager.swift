// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import WatchConnectivity
import os.log

nonisolated private struct WatchConnectivityDictionary: @unchecked Sendable {
    let value: [String: Any]
}

nonisolated private struct WatchConnectivityReplyHandler: @unchecked Sendable {
    let value: ([String: Any]) -> Void

    func callAsFunction(_ response: [String: Any]) {
        value(response)
    }
}

nonisolated private struct WatchConnectivityFile: @unchecked Sendable {
    let value: WCSessionFile
}

struct WatchDurableContextPolicy {
    var minimumProgressInterval: TimeInterval
    private var lastDurableContextRefresh: Date?

    init(minimumProgressInterval: TimeInterval = 30) {
        self.minimumProgressInterval = minimumProgressInterval
    }

    mutating func shouldRefreshDurableContext(
        reason: WatchSyncManager.SyncReason,
        context: [String: Any],
        now: Date = .now
    ) -> Bool {
        switch reason {
        case .significant:
            lastDurableContextRefresh = now
            return true
        case .progress:
            guard context["isPlaying"] as? Bool == true else { return false }
            guard let lastDurableContextRefresh else {
                self.lastDurableContextRefresh = now
                return true
            }
            guard now.timeIntervalSince(lastDurableContextRefresh) >= minimumProgressInterval else {
                return false
            }
            self.lastDurableContextRefresh = now
            return true
        }
    }
}

/// Deduplicates the large thumbnail transfer independently from complete state.
/// Comparing the stable artwork sequence, data, and logical key lets regenerated
/// base art replace an older image without requiring a track change. Explicit
/// absence resets the remembered transfer so the same image can be sent again.
struct WatchThumbnailTransferPolicy {
    private var lastTransfer: (artworkKey: String, data: Data, artworkSequence: Double)?

    mutating func payload(
        artworkKey: String?, data: Data?, artworkSequence: Double?
    ) -> [String: Any]? {
        guard let artworkKey, let data, let artworkSequence,
            artworkSequence.isFinite, artworkSequence > 0
        else {
            lastTransfer = nil
            return nil
        }

        if let lastTransfer,
            lastTransfer.artworkKey == artworkKey,
            lastTransfer.data == data,
            lastTransfer.artworkSequence == artworkSequence
        {
            return nil
        }

        lastTransfer = (artworkKey, data, artworkSequence)
        return [
            "artworkSeq": artworkSequence,
            "artworkKey": artworkKey,
            "thumbnailData": data,
        ]
    }
}

/// Manages bidirectional WatchConnectivity communication with the Apple Watch companion.
///
/// Uses closure-based callbacks rather than a delegate protocol so PlayerModel can wire
/// everything up in one `init()` block with weak-captured self.
///
/// The WatchSyncManager itself conforms to WCSessionDelegate and owns no domain knowledge
/// of audiobook playback, chapters, or bookmarks.
@MainActor
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

    private var thumbnailTransferPolicy = WatchThumbnailTransferPolicy()
    private var durableContextPolicy = WatchDurableContextPolicy()

    // MARK: - Init

    override init() {
        super.init()
        setup()
    }

    private func setup() {
        guard WCSession.isSupported() else { return }
        // Unit tests construct many PlayerModels; each would re-point and
        // re-activate the process-wide WCSession.default singleton, churning its
        // delegate and corrupting the framework's internal state (a double-free
        // that crashes the test process on the CI simulator). The app only ever
        // creates one PlayerModel, so skipping activation under XCTest is a no-op
        // in production — the env var is set only by the test runner.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
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
    /// remain live-first, while active playback periodically refreshes the
    /// application context so a locked or disconnected watch wakes with a recent
    /// "now" instead of the last significant transport change.
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
        if durableContextPolicy.shouldRefreshDurableContext(reason: reason, context: context) {
            #if DEBUG
                assertExpectedKeys(in: context)
            #endif
            do {
                try session.updateApplicationContext(context)
            } catch {
                os_log(
                    .error, "updateApplicationContext failed: %{private}@",
                    error.localizedDescription)
            }
        }

        // Live channel: low-latency push while the watch app is reachable. If it
        // is dropped, the application context above still carries the change.
        // WCSession invokes these handlers on a background queue; @Sendable keeps
        // them from inheriting WatchSyncManager's MainActor isolation.
        if session.isReachable {
            session.sendMessage(
                context,
                replyHandler: { @Sendable _ in },
                errorHandler: { @Sendable error in
                    os_log(
                        .error, "Live watch sync dropped (context still carries it): %{private}@",
                        error.localizedDescription)
                })
        }

        let artworkSequence = (context["artworkSeq"] as? NSNumber)?.doubleValue
        sendThumbnailIfNeeded(artworkSequence: artworkSequence)
    }

    private func sendThumbnailIfNeeded(artworkSequence: Double?) {
        let session = WCSession.default
        guard session.activationState == .activated,
            let (artworkKey, data) = thumbnailProvider?(),
            let payload = thumbnailTransferPolicy.payload(
                artworkKey: artworkKey, data: data, artworkSequence: artworkSequence)
        else { return }

        // Since thumbnail is large, transferUserInfo is still appropriate here
        // as updateApplicationContext overwrites and we don't want to lose the
        // main state payload. But we can merge it into a single context if we want.
        // For now, leave it as transferUserInfo to not disrupt main context.
        session.transferUserInfo(payload)
    }

    // MARK: - WCSessionDelegate

    nonisolated func session(
        _ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        guard activationState == .activated else {
            if let error {
                os_log(
                    .error, "WatchConnectivity activation failed: %{private}@",
                    error.localizedDescription)
            }
            return
        }
        Task { @MainActor [weak self] in
            self?.syncToWatch()
        }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any])
    {
        let payload = WatchConnectivityDictionary(value: message)
        Task { @MainActor [weak self, payload] in
            self?.onMessage?(payload.value, nil)
        }
    }

    nonisolated func session(
        _ session: WCSession, didReceiveMessage message: [String: Any],
        replyHandler: @escaping ([String: Any]) -> Void
    ) {
        let payload = WatchConnectivityDictionary(value: message)
        let reply = WatchConnectivityReplyHandler(value: replyHandler)
        Task { @MainActor [weak self, payload, reply] in
            self?.onMessage?(payload.value, reply.value)
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        let payload = WatchConnectivityDictionary(value: userInfo)
        Task { @MainActor [weak self, payload] in
            self?.onQueuedMessage?(payload.value)
        }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        let payload = WatchConnectivityFile(value: file)
        Task { @MainActor [weak self, payload] in
            self?.onReceiveFile?(payload.value)
        }
    }

    nonisolated func session(
        _ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]
    ) {
        let payload = WatchConnectivityDictionary(value: applicationContext)
        Task { @MainActor [weak self, payload] in
            self?.onReceiveApplicationContext?(payload.value)
        }
    }

    #if DEBUG
        /// Expected keys in every significant application-context dictionary sent to
        /// the watch. If a key is missing, the assertion fires so developers catch
        /// context drift at the source instead of debugging stale watch UIs.
        private let expectedContextKeys: Set<String> = [
            "isPlaying", "stateSeq", "artworkSeq", "progressFraction", "currentTime",
            "bookmarkStorageKey",
            "folderKey", "title", "crownAction", "isHapticFeedbackEnabled",
            "watchQuickBookmarkTimeoutSeconds", "loopMode", "playbackSpeed",
            "seekBackwardDuration", "seekForwardDuration",
            "watchPage1", "watchPage2", "watchPage3", "watchPage4", "watchPage5",
            "linearBarMode", "linearBarHidden", "circularRingMode",
            "circularRingHidden", "watchArtworkLayout", "watchBackgroundStyle",
            "watchTitleScrollEnabled", "artworkAccentColorHex",
        ]

        private func assertExpectedKeys(in context: [String: Any]) {
            let missing = expectedContextKeys.subtracting(context.keys)
            assert(missing.isEmpty, "Watch application context missing keys: \(missing.sorted())")
        }
    #endif
}
