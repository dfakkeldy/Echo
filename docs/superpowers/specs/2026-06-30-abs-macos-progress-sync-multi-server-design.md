# Audiobookshelf macOS Two-Way Sync + Multiple Saved Servers — Design

**Date:** 2026-06-30
**Status:** Approved
**Author:** Dan Fakkeldy + Claude

## 1. Context

PR #359 (merged into `nightly` 2026-06-30) closed every HIGH-severity macOS↔iOS parity gap except two ABS items, deliberately deferred: two-way listening-progress sync, and (a genuine scope expansion beyond iOS) saving multiple ABS servers with credentials. `MacAudiobookshelfViewModel` (`Echo macOS/Views/MacAudiobookshelfView.swift`) already does connect/browse/download-to-play over the shared, macOS-clean `AudiobookshelfService`/`ABSTokenStore`/`ABSImportService`/`ABSServerDAO`, but never pushes or pulls playback position, and `ABSServerDAO` is explicitly single-row (`save()` does `DELETE FROM abs_server` before every insert).

This design closes both gaps in one branch/PR, built off a fresh cut of `origin/nightly` (PR #359 is merged, so the prior `claude/macos-parity-waves-a-e` branch is done).

## 2. Discovery

- iOS's reference implementation, `EchoCore/ViewModels/PlayerModel+Audiobookshelf.swift`, keeps its ABS sync bookkeeping (`absService`, `absServiceServerID`, `absSyncRemoteItemID`, `absLastPushAt`) as `@ObservationIgnored` stored properties on `PlayerModel` itself (`EchoCore/ViewModels/PlayerModel.swift:69-78`) — Swift extensions cannot add stored properties, so the logic-only extension file is layered on top of state declared in the main class.
- The pure decision helpers are already macOS-clean and shared: `ABSProgressSync.shouldPush`/`isFinished` and `ABSProgressReconciler.decide` (`EchoCore/Services/Audiobookshelf/`), both with existing `EchoTests` coverage (`ABSProgressSyncTests`, `ABSProgressReconcilerTests`) — no new pure logic needed, only wiring.
- `MacPlaybackResumeState` (`Shared/MacPlaybackResumeState.swift`) already carries `updatedAt: Date` — no schema/struct change needed there, just convert to epoch-ms (`ABSProgressReconciler`'s documented convention, matching iOS's `PlaylistManifestService` `updatedAt = Date().timeIntervalSince1970 * 1000` and ABS's `ABSMediaProgressResponse.lastUpdate: Int64?`).
- Mac has no multi-m4b book-time axis (`cumulativePlaybackTime` on iOS has no Mac equivalent) — out of scope here, tracked separately as a future "Wave G" item. This design uses `MacPlayerModel.currentTime`/`.duration` directly, which is correct for single-track and single-file-per-chapter books and has the same single-track limitation Mac's local resume already has.
- `MacAudiobookshelfViewModel` is sheet-scoped (a fresh instance per "Connect to Audiobookshelf…" sheet open, `MacAudiobookshelfView.swift:233-235`) — it cannot own ongoing playback-progress sync, which must run for the lifetime of `MacPlayerModel` regardless of whether the sheet is open. `MacPlayerModel` therefore builds and caches its own independent `AudiobookshelfService`, exactly mirroring how iOS's `PlayerModel` is self-contained. Two independently-cached `AudiobookshelfService` instances (one per VM) each mint their own memory-only access token against the same Keychain-persisted refresh token — this is `ABSTokenStore`'s designed behavior, not a new sharing concern.
- `Shared/Database/DAOs/ABSServerDAO.swift`'s `save()` docstring is explicit: "v1 connects to at most one server." Latest registered migration is `v30_narration_quality_issue` (`Shared/Database/DatabaseService.swift:140`), so the new migration is `Schema_V31`.

## 3. Slice 1 — Two-way progress sync

### 3.1 New state (in `MacPlayerModel.swift`, mirroring `PlayerModel.swift:69-78`)

```swift
@ObservationIgnored private var absService: AudiobookshelfService?
@ObservationIgnored private var absServiceServerID: String?
@ObservationIgnored private var absSyncRemoteItemID: String?
@ObservationIgnored private var absLastPushAt: TimeInterval?
```

### 3.2 New file `Echo macOS/Views/MacPlayerModel+Audiobookshelf.swift`

Mirrors `PlayerModel+Audiobookshelf.swift`'s sync half only (connect/disconnect/browse stay owned by `MacAudiobookshelfViewModel` — no duplication):

- `absServerDAO: ABSServerDAO?` — via `dbService`.
- `makeAudiobookshelfService() -> AudiobookshelfService?` — warm-cache-first; on miss, reads `absServerDAO?.current()`, builds a trust-aware session via `ABSURLSession.make(expectedHost:pinnedSHA256:)` + `ABSTokenStore(serverID:)`, caches it.
- `refreshABSSyncIdentity()` — resets `absLastPushAt`; on a DB hit where `AudiobookDAO(db:).get(audiobookID)?.sourceType == "audiobookshelf"`, caches `remoteItemID` into `absSyncRemoteItemID`, else clears it.
- `maybePushABSProgress(force: Bool = false)` — no-op without a cached `absSyncRemoteItemID` + service; otherwise throttle-gated via `ABSProgressSync.shouldPush(now:lastPushAt:minInterval: 20, isPlaying:)` (skipped when `force`), pushes `currentTime`/`duration` via `service.patchProgress`, `isFinished` via `ABSProgressSync.isFinished`.
- `reconcileABSProgressOnLoad()` — no-op without identity; otherwise reads local `MacPlaybackResumeState.load(from: AppGroupDefaults.shared)?.updatedAt` (converted to epoch-ms), awaits `service.getProgress(itemID:)`, feeds both into `ABSProgressReconciler.decide(localTime:localUpdatedAt:remoteTime:remoteUpdatedAt:)`, and on `.seekLocalTo` calls `self.seek(to:)` on the main actor, on `.pushLocal` calls `maybePushABSProgress(force: true)`.

### 3.3 Hook points in `MacPlayerModel.swift`

| Site | Call | Why |
|---|---|---|
| `open(url:)`, right after `folderURL` resolution | `refreshABSSyncIdentity()` | Every load path (`loadFolder`, `loadNarratedBook`, `restoreLastFile`) funnels through `open(url:)`. |
| `open(url:)`, end (after `restoreResumePositionIfNeeded()`) | `reconcileABSProgressOnLoad()` | Async, after local restore — never blocks playback, same as iOS. |
| Periodic time-observer tick (alongside `persistResumeStateThrottled()`) | `maybePushABSProgress()` | Self-throttled to 20s while playing — the "continuous playback" push path. |
| `pause()` (alongside `persistResumeState()`) | `maybePushABSProgress(force: true)` | Flush immediately when the user stops actively listening. |
| `stop()` (alongside `persistResumeState()`, before state reset) | `maybePushABSProgress(force: true)` | `stop()` runs at the top of every book swap — flushes the outgoing book's final position, mirroring iOS's force-push at the top of `loadFolder(_:)`. |
| `seek(to:)` completion handler (alongside `persistResumeState()`) | `maybePushABSProgress()` | Cheap due to internal throttle; covers chapter/bookmark-loop seeks. |

**Deliberate simplification:** no `pendingBookTimeSeekSuppressesProgressPush`-equivalent guard. Mac never autoplays on load, and every `force: true` push site (`pause`/`stop`) only fires well after a load-time reconcile seek would have settled, with the now-correct post-seek position — so the "echo push immediately after a remote pull" failure mode iOS guards against can't occur in Mac's simpler, single-track timeline.

## 4. Slice 2 — Multiple saved servers

### 4.1 `Schema_V31` (`Shared/Database/Migrations/Schema_V31.swift`)

```swift
enum Schema_V31 {
    nonisolated static func migrate(_ db: Database) throws {
        // Idempotency guard mirrors Schema_V29's pattern (`hasColumn` check
        // before ALTER) rather than relying on `ifNotExists`, which `add(column:)`
        // does not support.
        let hasIsActive = try db.columns(in: "abs_server").contains { $0.name == "is_active" }
        guard !hasIsActive else { return }
        try db.alter(table: "abs_server") { t in
            t.add(column: "is_active", .boolean).notNull().defaults(to: false)
        }
        // Preserve "exactly one connected server" across the upgrade.
        try db.execute(sql: "UPDATE abs_server SET is_active = 1")
    }
}
```

Registered as `v31_abs_server_multi` in `DatabaseService.swift`, after `v30_narration_quality_issue`.

### 4.2 `ABSServerDAO` (`Shared/Database/DAOs/ABSServerDAO.swift`)

```swift
struct ABSServerRecord {
    ...
    var isActive: Bool = false   // CodingKeys: case isActive = "is_active"
}

struct ABSServerDAO {
    func current() throws -> ABSServerRecord?       // the active row (same semantics iOS relies on)
    func all() throws -> [ABSServerRecord]          // every saved server, newest-added first
    func upsert(_ server: ABSServerRecord) throws    // insert-or-update by id; does not change active
    func setActive(_ id: String) throws              // exclusive: clears is_active elsewhere first
    func delete(_ id: String) throws                 // unchanged
}
```

`save()` is removed. Its one call site, `PlayerModel+Audiobookshelf.connectAudiobookshelf` (iOS), becomes `try dao.upsert(record); try dao.setActive(record.id)` — iOS still ends up with exactly one *active* row in the only flow that can add a server without disconnecting first, so behavior is unchanged from iOS's perspective.

### 4.3 `MacAudiobookshelfViewModel` (`Echo macOS/Views/MacAudiobookshelfView.swift`)

- `enum Phase { case disconnected, connecting, connected, addingServer }`
- `var savedServers: [ABSServerRecord] = []`, refreshed in `load()` and after connect/switch/remove.
- `attemptConnect` calls `dao.upsert(record)` + `dao.setActive(record.id)` instead of `dao.save(record)`.
- `switchTo(_ server: ABSServerRecord) async` — invalidates the current `service` (mirrors iOS's `absService?.invalidate()` before reassigning), builds a fresh service for `server`, calls `dao.setActive(server.id)`, reloads libraries. Does **not** touch Keychain tokens — switching back later needs the still-valid refresh token.
- `removeSavedServer(_ server: ABSServerRecord) async` — same as today's `disconnect()` (remote sign-out + `ABSTokenStore(serverID:).clear()` + `dao.delete(id)`), parameterized by server; if it was active, falls back to `phase = .disconnected`, otherwise stays `.connected`.
- `beginAddingServer()` / `cancelAddingServer()` — toggle `.addingServer`, clearing/restoring form fields; preserves the currently-connected session so "Add Server" doesn't disconnect anything.

### 4.4 UI (`MacAudiobookshelfView`)

A "Servers" button in the sheet header (next to "Sign Out") opens a `.popover` listing `savedServers` (active one checked), each row offering Switch / Remove, plus an "Add Server…" row that calls `beginAddingServer()`.

## 5. Testing

- `EchoTests/Schema_V31Tests.swift` (or extend an existing `SchemaVxxTests` file if one groups recent migrations) — applies the migration to an in-memory DB seeded with a pre-V31 single `abs_server` row, asserts `is_active = 1` survives.
- Extend `EchoTests/MacAudiobookshelfParityTests.swift` (`MacSource`-based, since `Echo macOS` isn't compiled into `EchoTests`) with structural assertions for: the new `MacPlayerModel+Audiobookshelf.swift` hook wiring, the `Phase.addingServer` case, and `setActive`/`upsert`/`all(` usage in the view model. `#expect(...)` messages must be string literals, never `+`-concatenated (bitten every prior wave this session).
- `EchoTests/ABSServerDAOTests.swift` (new, or extend if one exists) for `all()`/`setActive(id:)`/`upsert(_:)` against a real in-memory `DatabaseService(inMemory:)`.

## 6. Verification & rollout

Build `Echo macOS` (`xcodebuild build -scheme "Echo macOS" -destination 'platform=macOS' -jobs 4 CODE_SIGNING_ALLOWED=NO`) and `make build-tests` sequentially — never concurrently (16GB machine) — before every commit, run from the main agent with an explicit `cd` to the worktree. Commit per slice (Slice 1, then Slice 2), push to a fresh PR against `nightly` (PR #359 already merged), check `gh pr checks`.
