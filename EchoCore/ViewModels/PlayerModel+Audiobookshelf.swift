// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension PlayerModel {
    /// DAO for the single connected ABS server. nil if the DB isn't ready yet.
    var absServerDAO: ABSServerDAO? {
        guard let writer = databaseService?.writer else { return nil }
        return ABSServerDAO(db: writer)
    }

    /// Connect + persist the server (non-secret) and tokens (Keychain). Caches the warm,
    /// logged-in service instance.
    @discardableResult
    func connectAudiobookshelf(baseURL: URL, username: String, password: String) async throws
        -> ABSServerRecord
    {
        guard let dao = absServerDAO else { throw ABSError.notConnected }
        let serverID = UUID().uuidString
        let tokens = ABSTokenStore(serverID: serverID)
        let service = AudiobookshelfService(baseURL: baseURL, tokens: tokens, session: .shared)
        let defaultLib = try await service.login(username: username, password: password)
        let record = ABSServerRecord(
            id: serverID,
            baseURL: baseURL.absoluteString,
            username: username,
            defaultLibraryId: defaultLib,
            addedAt: ISO8601DateFormatter().string(from: Date()))
        try dao.save(record)
        absService = service  // cache the warm instance (keeps access token + refresh serialization)
        absServiceServerID = serverID
        return record
    }

    func disconnectAudiobookshelf(_ server: ABSServerRecord) async {
        let service = makeAudiobookshelfService()  // reuse cached instance if present
        await service?.signOut()
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
        let service = AudiobookshelfService(
            baseURL: url, tokens: ABSTokenStore(serverID: server.id), session: .shared)
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
        let duration = durationSeconds ?? 0
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
        let folder = try await importer.prepareLocalFolder(for: item)
        loadFolder(folder, autoplay: false)
    }
}
