// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import UIKit

extension PlayerModel {
    /// DAO for the single connected ABS server. nil if the DB isn't ready yet.
    var absServerDAO: ABSServerDAO? {
        guard let writer = databaseService?.writer else { return nil }
        return ABSServerDAO(db: writer)
    }

    /// Connect + persist the server (non-secret) and tokens (Keychain). Always uses a delegate-backed
    /// session so self-signed certs can be pinned. On first connect to a self-signed host (no pin
    /// yet) `login()` throws `ABSError.untrustedCertificate` — the connect UI shows the fingerprint
    /// and, on approval, calls this again with `trustingCertificate:` set. CA-trusted and `http://`
    /// servers succeed on the first call with `pinnedSHA256 == nil` (the delegate just defers to
    /// default handling).
    @discardableResult
    func connectAudiobookshelf(
        baseURL: URL, username: String, password: String,
        trustingCertificate pinnedSHA256: String? = nil
    ) async throws -> ABSServerRecord {
        guard let dao = absServerDAO else { throw ABSError.notConnected }
        let serverID = UUID().uuidString
        let host = baseURL.host?.lowercased() ?? ""
        let tokens = ABSTokenStore(serverID: serverID)
        if let pinnedSHA256 { tokens.pinnedCertificateSHA256 = pinnedSHA256 }
        let (session, delegate) = ABSURLSession.make(expectedHost: host, pinnedSHA256: pinnedSHA256)
        let service = AudiobookshelfService(
            baseURL: baseURL, tokens: tokens, session: session, trustDelegate: delegate)

        let defaultLib: String?
        do {
            defaultLib = try await service.login(username: username, password: password)
        } catch {
            service.invalidate()
            // Roll back the pin we optimistically wrote if a *trust* connect failed for some other
            // reason (wrong password, etc.), so a stale pin can't linger for an unsaved server.
            if pinnedSHA256 != nil { tokens.clear() }
            throw error
        }

        let record = ABSServerRecord(
            id: serverID, baseURL: baseURL.absoluteString, username: username,
            defaultLibraryId: defaultLib,
            addedAt: ISO8601DateFormatter().string(from: Date()))
        try dao.save(record)
        absService?.invalidate()  // release any previously-cached delegate session
        absService = service  // cache the warm instance (access token + refresh serialization)
        absServiceServerID = serverID
        return record
    }

    func disconnectAudiobookshelf(_ server: ABSServerRecord) async {
        let service = makeAudiobookshelfService()  // reuse cached instance if present
        await service?.signOut()  // clears access/refresh + the pinned cert
        service?.invalidate()  // release the delegate-backed session
        try? absServerDAO?.delete(server.id)
        absService = nil
        absServiceServerID = nil
    }

    /// The SINGLE, cached service for the connected server. ONE instance is required for
    /// CORRECTNESS, not just efficiency: `ABSTokenStore.accessToken` is memory-only per
    /// instance (a fresh service per call discards the login's access token and forces a
    /// refresh every time), and the `inFlightRefresh` serialization (Task A5) is per
    /// instance (fresh instances let concurrent refreshes collide — the exact /auth/refresh
    /// self-invalidation that A5 prevents). Browse, import, and progress-push MUST all go
    /// through this one accessor. Warm cache returns FIRST, before any DB read (this is
    /// called per-row by the Browse cover builder).
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

    // MARK: - Progress sync

    /// Cache whether the currently-loaded book is ABS-sourced (so the hot save path is a
    /// cheap nil-check, not a DB hit every tick). Call when a book finishes loading.
    func refreshABSSyncIdentity() {
        absLastPushAt = nil
        guard let db = databaseService,
            let id = folderURL?.absoluteString,
            let record = try? AudiobookDAO(db: db.writer).get(id)
        else {
            absSyncRemoteItemID = nil
            return
        }
        absSyncRemoteItemID = record.sourceType == "audiobookshelf" ? record.remoteItemID : nil
    }

    /// Throttled push of the current book-absolute position to ABS. No-op for non-ABS books.
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
        let current = cumulativePlaybackTime
        // Whole-book duration: `current` is book-absolute (cumulativePlaybackTime),
        // so it must be divided by the whole-book span, not the current track's
        // `durationSeconds` — otherwise multi-M4B books read as finished after the
        // first track (CODE_AUDIT §5.20).
        let duration = state.effectiveBookDuration
        let finished = ABSProgressSync.isFinished(currentTime: current, duration: duration)
        Task {
            try? await service.patchProgress(
                itemID: itemID, currentTime: current, duration: duration, isFinished: finished)
        }
    }

    /// On ABS-book load: pull ABS progress, reconcile vs local, and either re-seek (single-track
    /// only in v1) or push local. Runs async after the normal local restore; never blocks playback.
    func reconcileABSProgressOnLoad() {
        guard let itemID = absSyncRemoteItemID, let service = makeAudiobookshelfService(),
            let folder = folderURL
        else { return }
        let localUpdatedAt = PlaylistManifestService.read(from: folder)?.playbackState.updatedAt
        Task { [weak self] in
            guard let remote = try? await service.getProgress(itemID: itemID) else { return }
            guard let self else { return }
            let decision = ABSProgressReconciler.decide(
                localTime: self.cumulativePlaybackTime,
                localUpdatedAt: localUpdatedAt,
                remoteTime: remote.currentTime,
                remoteUpdatedAt: remote.lastUpdate.map(Double.init))
            switch decision {
            case .seekLocalTo(let target):
                // v1: only override-seek single-track books (book time == track time → safe).
                if self.tracks.count == 1, target >= 0,
                    target <= (self.durationSeconds ?? .greatestFiniteMagnitude)
                {
                    await MainActor.run { self.seek(toSeconds: target) }
                }
            case .pushLocal:
                self.maybePushABSProgress(force: true)
            case .noop:
                break
            }
        }
    }

    /// Download an ABS item into the local library and start loading it.
    func addFromAudiobookshelf(_ item: ABSLibraryItem) async throws {
        guard let service = makeAudiobookshelfService(), let db = databaseService else {
            throw ABSError.notConnected
        }
        guard let serverID = absServiceServerID ?? (try? absServerDAO?.current())?.id,
            !serverID.isEmpty
        else {
            throw ABSError.notConnected
        }
        let importer = ABSImportService(service: service, db: db, serverID: serverID)
        // Background-task grace window: if the user backgrounds the app mid-import, the OS
        // grants ~30s–3min so an in-flight download can finish rather than being suspended
        // immediately. Full background-`URLSession` resumption is a future enhancement — the
        // ABS whole-item zip has no Content-Length / byte-range support, so it can't truly
        // resume; this covers the common "switch apps while it downloads" case.
        let bgTask = UIApplication.shared.beginBackgroundTask(withName: "abs-import")
        defer { if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) } }
        let folder = try await importer.prepareLocalFolder(for: item)
        loadFolder(folder, autoplay: false)
    }
}
