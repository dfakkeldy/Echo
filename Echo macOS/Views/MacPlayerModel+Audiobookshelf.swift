// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// macOS counterpart to `PlayerModel+Audiobookshelf.swift`'s progress-sync half.
/// Connect/disconnect/browse/import stay owned by `MacAudiobookshelfViewModel`
/// (sheet-scoped, dies when the "Connect to Audiobookshelf…" sheet closes) — this
/// extension gives the long-lived `MacPlayerModel` its own independent
/// `AudiobookshelfService` so progress keeps syncing whether or not that sheet is
/// open. Two independently-cached `AudiobookshelfService` instances each mint
/// their own memory-only access token against the same Keychain-persisted
/// refresh token (`ABSTokenStore`'s designed per-instance behavior) — this is
/// not a new sharing concern.
extension MacPlayerModel {
    /// DAO for the connected ABS server. nil if the DB isn't ready yet.
    var absServerDAO: ABSServerDAO? {
        guard let writer = dbService?.writer else { return nil }
        return ABSServerDAO(db: writer)
    }

    /// The cached service for the active connected server, building one on
    /// first use. Warm cache returns first, before any DB read.
    func makeAudiobookshelfService() -> AudiobookshelfService? {
        if let cached = absService { return cached }
        guard let dao = absServerDAO,
            let server = try? dao.current(),
            let url = URL(string: server.baseURL)
        else { return nil }
        let tokens = ABSTokenStore(serverID: server.id)
        let host = url.host?.lowercased() ?? ""
        let (session, delegate) = ABSURLSession.make(
            expectedHost: host, pinnedSHA256: tokens.pinnedCertificateSHA256)
        let service = AudiobookshelfService(
            baseURL: url, tokens: tokens, session: session, trustDelegate: delegate)
        absService = service
        absServiceServerID = server.id
        return service
    }

    /// Drops the cached service so the next call to `makeAudiobookshelfService()`
    /// rebuilds against whichever server is now active. Call after switching or
    /// removing a saved server.
    func invalidateAudiobookshelfServiceCache() {
        absService?.invalidate()
        absService = nil
        absServiceServerID = nil
    }

    // MARK: - Progress sync

    /// Caches whether the currently-loaded book is ABS-sourced, so the hot save
    /// path (every periodic tick) is a cheap nil-check, not a DB hit per tick.
    /// Call on every book load.
    func refreshABSSyncIdentity() {
        absLastPushAt = nil
        guard let db = dbService,
            let id = audiobookID,
            let record = try? AudiobookDAO(db: db.writer).get(id)
        else {
            absSyncRemoteItemID = nil
            return
        }
        absSyncRemoteItemID = record.sourceType == "audiobookshelf" ? record.remoteItemID : nil
    }

    /// Throttled push of the current playback position to ABS. No-op for
    /// non-ABS books. Mac has no multi-m4b book-time axis yet (a separately
    /// tracked future item), so `currentTime`/`duration` — the current track
    /// only — are pushed directly; this is the same single-track limitation
    /// Mac's local resume already has.
    func maybePushABSProgress(force: Bool = false) {
        guard let itemID = absSyncRemoteItemID, let service = makeAudiobookshelfService() else {
            return
        }
        let now = Date().timeIntervalSince1970
        guard
            force
                || ABSProgressSync.shouldPush(
                    now: now, lastPushAt: absLastPushAt, minInterval: 20, isPlaying: isPlaying)
        else { return }
        absLastPushAt = now
        let current = currentTime
        let total = duration
        let finished = ABSProgressSync.isFinished(currentTime: current, duration: total)
        Task {
            try? await service.patchProgress(
                itemID: itemID, currentTime: current, duration: total, isFinished: finished)
        }
    }

    /// On ABS-book load: pulls ABS progress, reconciles vs local, and either
    /// re-seeks or pushes local. Runs async after the normal local restore;
    /// never blocks playback.
    func reconcileABSProgressOnLoad() {
        guard let itemID = absSyncRemoteItemID, let service = makeAudiobookshelfService() else {
            return
        }
        let localUpdatedAt: Double? = MacPlaybackResumeState.load(from: AppGroupDefaults.shared)
            .map { $0.updatedAt.timeIntervalSince1970 * 1000 }
        Task { [weak self] in
            guard let remote = try? await service.getProgress(itemID: itemID) else { return }
            guard let self else { return }
            let decision = ABSProgressReconciler.decide(
                localTime: self.currentTime,
                localUpdatedAt: localUpdatedAt,
                remoteTime: remote.currentTime,
                remoteUpdatedAt: remote.lastUpdate.map(Double.init))
            switch decision {
            case .seekLocalTo(let target):
                guard target >= 0 else { return }
                self.seek(to: target)
            case .pushLocal:
                self.maybePushABSProgress(force: true)
            case .noop:
                break
            }
        }
    }
}
