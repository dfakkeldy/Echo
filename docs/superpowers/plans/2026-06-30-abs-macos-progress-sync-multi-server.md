# Audiobookshelf macOS Two-Way Sync + Multiple Saved Servers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give macOS two-way Audiobookshelf playback-progress sync (mirroring iOS's `PlayerModel+Audiobookshelf.swift`) and support for saving multiple ABS servers with credentials (a real shared `Schema_V31` migration, not a macOS-only hack).

**Architecture:** Slice 1 adds a `MacPlayerModel+Audiobookshelf.swift` extension that builds its own independent, cached `AudiobookshelfService` and wires throttled push / load-time reconcile into `MacPlayerModel`'s existing play/pause/stop/seek/persist hooks, reusing the already-shared, already-tested `ABSProgressSync`/`ABSProgressReconciler` pure helpers. Slice 2 converts `abs_server` from a single-row to a multi-row table (`is_active` flag), replaces `ABSServerDAO.save()` with `upsert`/`setActive`/`all`, and adds a "Saved Servers" section to `MacAudiobookshelfView`'s existing connect sheet.

**Tech Stack:** Swift 6, SwiftUI (macOS), GRDB (SQLite), Swift Testing (`@Test`/`#expect`/`#require`).

## Global Constraints

- 16GB build machine: never run two `xcodebuild` invocations concurrently, never enable parallel testing. Build `Echo macOS` and run `make build-tests` **sequentially**, always from an explicit `cd` to the worktree (a prior session this branch's history saw shell cwd silently drift back to the main repo mid-session).
- `#expect(...)` message arguments must be single string **literals** — never `"a" + "b"` concatenation (only literals convert to `Comment?`; every prior macOS-parity wave this session got bitten by this).
- `Echo macOS` is not compiled into the `EchoTests` target — macOS-only behavior is verified via `MacSource.read(_:)` source-text assertions in `EchoTests/MacAudiobookshelfParityTests.swift`, plus a real `xcodebuild build -scheme "Echo macOS"` for actual compilation.
- Never push to `nightly`/`weekly`/`main` directly. This branch (`claude/happy-hertz-be98c1`, already at `origin/nightly` tip) is the feature branch; PR targets `nightly` (PR #359, which covered the rest of this parity program, is already merged).
- Conventional Commits for every commit message.
- `Column("...")` in GRDB queries against these records takes the **SQL column name** (e.g. `"is_active"`, `"added_at"`), not the Swift property name — confirmed by the existing `AudiobookDAO.all()` (`Column("added_at")`).

---

### Task 1: MacPlayerModel ABS sync engine

**Files:**
- Modify: `Echo macOS/Views/MacPlayerModel.swift:216-218` (add 4 stored properties)
- Create: `Echo macOS/Views/MacPlayerModel+Audiobookshelf.swift`
- Test: `EchoTests/MacAudiobookshelfParityTests.swift` (append)

**Interfaces:**
- Consumes: `MacPlayerModel.dbService: DatabaseService?`, `.audiobookID: String?`, `.currentTime: Double`, `.duration: Double`, `.isPlaying: Bool`, `.seek(to: Double)` (all pre-existing). `ABSServerDAO.current() throws -> ABSServerRecord?` (pre-existing, unchanged signature in this task — Task 4 changes its *implementation*, not its signature). `ABSTokenStore(serverID: String)`, `ABSURLSession.make(expectedHost:pinnedSHA256:) -> (session: URLSession, delegate: ABSServerTrustDelegate)`, `AudiobookshelfService.init(baseURL:tokens:session:trustDelegate:)`, `AudiobookshelfService.invalidate()`, `.getProgress(itemID:) async throws -> ABSMediaProgressResponse?`, `.patchProgress(itemID:currentTime:duration:isFinished:) async throws` (all pre-existing, unchanged). `ABSProgressSync.shouldPush(now:lastPushAt:minInterval:isPlaying:) -> Bool`, `.isFinished(currentTime:duration:tailSeconds:) -> Bool` (pre-existing, pure). `ABSProgressReconciler.decide(localTime:localUpdatedAt:remoteTime:remoteUpdatedAt:thresholdSeconds:) -> ABSProgressDecision` (pre-existing, pure). `MacPlaybackResumeState.load(from:) -> MacPlaybackResumeState?` with `.updatedAt: Date` (pre-existing). `AppGroupDefaults.shared` (pre-existing). `AudiobookDAO(db:).get(_:) throws -> AudiobookRecord?` with `.sourceType: String?`, `.remoteItemID: String?` (pre-existing).
- Produces: `MacPlayerModel.absServerDAO: ABSServerDAO?`, `.makeAudiobookshelfService() -> AudiobookshelfService?`, `.invalidateAudiobookshelfServiceCache()`, `.refreshABSSyncIdentity()`, `.maybePushABSProgress(force: Bool = false)`, `.reconcileABSProgressOnLoad()` — all consumed by Task 2 (hook wiring) and Task 5 (`invalidateAudiobookshelfServiceCache()` consumed when switching/removing a saved server).

- [ ] **Step 1: Write the failing structural test**

Append to `EchoTests/MacAudiobookshelfParityTests.swift`, before the struct's closing `}`:

```swift
    @Test func syncsProgressViaIndependentService() throws {
        let src = try MacSource.read("Views/MacPlayerModel+Audiobookshelf.swift")
        #expect(
            src.contains("func makeAudiobookshelfService()") && src.contains("ABSServerDAO"),
            "MacPlayerModel must build its own independent AudiobookshelfService so sync keeps working when the Connect sheet is closed."
        )
        #expect(
            src.contains("func refreshABSSyncIdentity()")
                && src.contains("sourceType == \"audiobookshelf\""),
            "Sync identity must be cached from AudiobookDAO on book load.")
        #expect(
            src.contains("func maybePushABSProgress(") && src.contains("ABSProgressSync.shouldPush("),
            "Progress push must be throttled via the shared ABSProgressSync policy.")
        #expect(
            src.contains("func reconcileABSProgressOnLoad()")
                && src.contains("ABSProgressReconciler.decide("),
            "Load-time reconciliation must use the shared ABSProgressReconciler.")
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd "/Users/dfakkeldy/Developer/Echo/.claude/worktrees/happy-hertz-be98c1" && make test-only FILTER=EchoTests/MacAudiobookshelfParityTests`
Expected: FAIL — `MacSource.MacSourceError.notFound("Views/MacPlayerModel+Audiobookshelf.swift")` (file doesn't exist yet).

- [ ] **Step 3: Add the 4 stored properties to `MacPlayerModel.swift`**

In `Echo macOS/Views/MacPlayerModel.swift`, immediately after the existing line `private var didStartLastFileRestore = false` (around line 218), insert:

```swift
    // MARK: - Audiobookshelf two-way sync (see MacPlayerModel+Audiobookshelf.swift)
    @ObservationIgnored private var absService: AudiobookshelfService?
    @ObservationIgnored private var absServiceServerID: String?
    @ObservationIgnored private var absSyncRemoteItemID: String?
    @ObservationIgnored private var absLastPushAt: TimeInterval?
```

- [ ] **Step 4: Create `Echo macOS/Views/MacPlayerModel+Audiobookshelf.swift`**

```swift
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
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `cd "/Users/dfakkeldy/Developer/Echo/.claude/worktrees/happy-hertz-be98c1" && make test-only FILTER=EchoTests/MacAudiobookshelfParityTests`
Expected: PASS (all 4 tests in the suite, including the 3 pre-existing ones).

- [ ] **Step 6: Build `Echo macOS` to confirm the extension actually compiles**

Run: `cd "/Users/dfakkeldy/Developer/Echo/.claude/worktrees/happy-hertz-be98c1" && "$HOME/.claude/bin/xcode-build-gate.sh" --wait && xcodebuild build -scheme "Echo macOS" -destination 'platform=macOS' -jobs 4 CODE_SIGNING_ALLOWED=NO`
Expected: `** BUILD SUCCEEDED **`. (`MacSource`-based tests only check source text, not real compilation — this step is the actual compile check for macOS-only code.)

- [ ] **Step 7: Commit**

```bash
cd "/Users/dfakkeldy/Developer/Echo/.claude/worktrees/happy-hertz-be98c1"
git add "Echo macOS/Views/MacPlayerModel.swift" "Echo macOS/Views/MacPlayerModel+Audiobookshelf.swift" EchoTests/MacAudiobookshelfParityTests.swift
git commit -m "feat(macos): add independent ABS sync engine to MacPlayerModel

Mirrors PlayerModel+Audiobookshelf.swift's progress-sync half: an
independently-cached AudiobookshelfService plus throttled push /
load-time reconcile over the shared ABSProgressSync/ABSProgressReconciler
helpers. Not yet wired into playback hooks (Task 2)."
```

---

### Task 2: Wire progress sync into MacPlayerModel's playback hooks

**Files:**
- Modify: `Echo macOS/Views/MacPlayerModel.swift` (5 call sites: `open(url:)` x2, periodic tick, `pause()`, `stop()`, `seek(to:)`)
- Test: `EchoTests/MacAudiobookshelfParityTests.swift` (append)

**Interfaces:**
- Consumes: the 5 methods Task 1 produced on `MacPlayerModel` (`refreshABSSyncIdentity()`, `reconcileABSProgressOnLoad()`, `maybePushABSProgress(force:)`).
- Produces: nothing new for later tasks — this task only wires existing methods into existing call sites.

- [ ] **Step 1: Write the failing structural test**

Append to `EchoTests/MacAudiobookshelfParityTests.swift`, before the struct's closing `}`:

```swift
    @Test func wiresProgressSyncIntoPlaybackHooks() throws {
        let src = try MacSource.read("Views/MacPlayerModel.swift")
        #expect(
            src.contains("refreshABSSyncIdentity()") && src.contains("reconcileABSProgressOnLoad()"),
            "Loading a book must refresh ABS sync identity and reconcile remote progress.")
        #expect(
            src.contains("maybePushABSProgress()"),
            "The periodic time observer must push throttled ABS progress while playing.")
        #expect(
            src.contains("maybePushABSProgress(force: true)"),
            "Pause and stop must force-flush ABS progress immediately.")
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd "/Users/dfakkeldy/Developer/Echo/.claude/worktrees/happy-hertz-be98c1" && make test-only FILTER=EchoTests/MacAudiobookshelfParityTests`
Expected: FAIL on `wiresProgressSyncIntoPlaybackHooks` — none of the 3 marker strings are present in `MacPlayerModel.swift` yet.

- [ ] **Step 3: Wire `open(url:)`**

In `Echo macOS/Views/MacPlayerModel.swift`, the `open(url:)` method currently has this block:

```swift
        // Infer folder from the file's parent directory if not already set.
        if folderURL == nil {
            folderURL = url.deletingLastPathComponent()
        }
```

Change to:

```swift
        // Infer folder from the file's parent directory if not already set.
        if folderURL == nil {
            folderURL = url.deletingLastPathComponent()
        }
        refreshABSSyncIdentity()
```

And the end of the same method currently reads:

```swift
        loadBookmarksFromDB()
        migrateLegacyBookmarksIfNeeded()
        loadChapters(for: url)
        restoreResumePositionIfNeeded()
    }
```

Change to:

```swift
        loadBookmarksFromDB()
        migrateLegacyBookmarksIfNeeded()
        loadChapters(for: url)
        restoreResumePositionIfNeeded()
        reconcileABSProgressOnLoad()
    }
```

- [ ] **Step 4: Wire the periodic time observer**

The periodic time observer's tick closure currently ends:

```swift
                self.handleChapterBoundary()
                self.handleBookmarkLoop()
                self.refreshCurrentChapter()
                self.persistResumeStateThrottled()
            }
        }
```

Change to:

```swift
                self.handleChapterBoundary()
                self.handleBookmarkLoop()
                self.refreshCurrentChapter()
                self.persistResumeStateThrottled()
                self.maybePushABSProgress()
            }
        }
```

- [ ] **Step 5: Wire `pause()` and `stop()`**

`pause()` currently reads:

```swift
    func pause() {
        if isPlaying { pausedAt = Date() }
        player?.pause()
        isPlaying = false
        persistResumeState()
        updateNowPlaying()
    }
```

Change to:

```swift
    func pause() {
        if isPlaying { pausedAt = Date() }
        player?.pause()
        isPlaying = false
        persistResumeState()
        maybePushABSProgress(force: true)
        updateNowPlaying()
    }
```

`stop()` currently starts:

```swift
    func stop() {
        persistResumeState()
        if let timeObserver, let player {
```

Change to:

```swift
    func stop() {
        persistResumeState()
        maybePushABSProgress(force: true)
        if let timeObserver, let player {
```

(Placed before the player/timeObserver teardown below it, so `currentTime`/`duration` are still the outgoing book's real values — `stop()` runs at the top of every book swap, mirroring iOS's force-push at the top of `loadFolder(_:)`.)

- [ ] **Step 6: Wire `seek(to:)`**

`seek(to:)` currently reads:

```swift
    func seek(to seconds: Double) {
        guard let player = self.player else { return }
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentTime = seconds
                self.persistResumeState()
            }
        }
    }
```

Change to:

```swift
    func seek(to seconds: Double) {
        guard let player = self.player else { return }
        let target = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.currentTime = seconds
                self.persistResumeState()
                self.maybePushABSProgress()
            }
        }
    }
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `cd "/Users/dfakkeldy/Developer/Echo/.claude/worktrees/happy-hertz-be98c1" && make test-only FILTER=EchoTests/MacAudiobookshelfParityTests`
Expected: PASS (all 5 tests in the suite).

- [ ] **Step 8: Build `Echo macOS` and run the full iOS test-target build**

Run sequentially (never concurrently):
```bash
cd "/Users/dfakkeldy/Developer/Echo/.claude/worktrees/happy-hertz-be98c1"
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && xcodebuild build -scheme "Echo macOS" -destination 'platform=macOS' -jobs 4 CODE_SIGNING_ALLOWED=NO
```
Expected: `** BUILD SUCCEEDED **`. Then:
```bash
cd "/Users/dfakkeldy/Developer/Echo/.claude/worktrees/happy-hertz-be98c1"
make build-tests
```
Expected: build succeeds (iOS test target, includes `EchoTests`).

- [ ] **Step 9: Commit**

```bash
cd "/Users/dfakkeldy/Developer/Echo/.claude/worktrees/happy-hertz-be98c1"
git add "Echo macOS/Views/MacPlayerModel.swift" EchoTests/MacAudiobookshelfParityTests.swift
git commit -m "feat(macos): wire ABS progress sync into MacPlayerModel playback hooks

refreshABSSyncIdentity()/reconcileABSProgressOnLoad() run on every book
load; maybePushABSProgress() fires from the periodic tick (throttled)
and force-fires on pause/stop/seek, completing slice 1 of the deferred
ABS macOS parity work."
```

---

### Task 3: Schema_V31 — multi-server migration

**Files:**
- Create: `Shared/Database/Migrations/Schema_V31.swift`
- Modify: `Shared/Database/DatabaseService.swift:140-142` (register migration)
- Test: Create `EchoTests/SchemaV31Tests.swift`

**Interfaces:**
- Consumes: GRDB `Database`, `DatabaseQueue`, `Row` (framework types). `DatabaseService(inMemory: ())` (pre-existing test seam).
- Produces: `Schema_V31.migrate(_ db: Database) throws` — consumed by `DatabaseService.runMigrations` (registered here) and by Task 4's DAO (which depends on the `is_active` column existing).

- [ ] **Step 1: Write the failing migration tests**

Create `EchoTests/SchemaV31Tests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor @Suite struct SchemaV31Tests {
    private func columnNames(table: String, db: DatabaseService) throws -> Set<String> {
        try db.writer.read { database in
            let rows = try Row.fetchAll(database, sql: "PRAGMA table_info(\(table))")
            return Set(rows.compactMap { $0["name"] as? String })
        }
    }

    @Test func v31AddsIsActiveColumn() throws {
        let db = try DatabaseService(inMemory: ())
        let cols = try columnNames(table: "abs_server", db: db)
        #expect(cols.contains("is_active"))
    }

    @Test func v31BackfillsExistingServerAsActive() throws {
        let queue = try DatabaseQueue()
        try queue.write { db in
            try db.create(table: "abs_server") { t in
                t.column("id", .text).primaryKey()
                t.column("base_url", .text).notNull()
                t.column("username", .text).notNull()
                t.column("default_library_id", .text)
                t.column("added_at", .text).notNull()
            }
            try db.execute(
                sql: """
                    INSERT INTO abs_server (id, base_url, username, default_library_id, added_at)
                    VALUES ('server-one', 'https://one.local:13378', 'reader', NULL, '2026-06-01T00:00:00Z')
                    """)
            try Schema_V31.migrate(db)
        }
        let isActive = try queue.read { db in
            try Bool.fetchOne(db, sql: "SELECT is_active FROM abs_server WHERE id = 'server-one'")
        }
        #expect(isActive == true)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd "/Users/dfakkeldy/Developer/Echo/.claude/worktrees/happy-hertz-be98c1" && make build-tests && make test-only FILTER=EchoTests/SchemaV31Tests`
Expected: build FAILS — `Schema_V31` does not exist yet (this is the TDD "fail" for a new-type test; the build error itself is the expected failure signal).

- [ ] **Step 3: Create `Shared/Database/Migrations/Schema_V31.swift`**

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

/// V31 — converts `abs_server` from a single-row table into a true multi-row
/// table with an `is_active` flag, enabling macOS's multiple-saved-servers UI.
/// `current()` keeps meaning "the active server" for iOS, which still only
/// ever activates one row in its only add-a-server flow.
enum Schema_V31 {
    nonisolated static func migrate(_ db: Database) throws {
        // Idempotency guard mirrors Schema_V29's pattern (`hasColumn` check
        // before ALTER) rather than relying on `ifNotExists`, which
        // `add(column:)` does not support.
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

- [ ] **Step 4: Register the migration in `DatabaseService.swift`**

In `Shared/Database/DatabaseService.swift`, the migration registration block currently ends:

```swift
        migrator.registerMigration("v30_narration_quality_issue") { db in
            try Schema_V30.migrate(db)
        }
        try migrator.migrate(writer)
```

Change to:

```swift
        migrator.registerMigration("v30_narration_quality_issue") { db in
            try Schema_V30.migrate(db)
        }
        migrator.registerMigration("v31_abs_server_multi") { db in
            try Schema_V31.migrate(db)
        }
        try migrator.migrate(writer)
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd "/Users/dfakkeldy/Developer/Echo/.claude/worktrees/happy-hertz-be98c1" && make build-tests && make test-only FILTER=EchoTests/SchemaV31Tests`
Expected: PASS (both tests).

- [ ] **Step 6: Run the full iOS test suite to confirm no regressions**

Run: `cd "/Users/dfakkeldy/Developer/Echo/.claude/worktrees/happy-hertz-be98c1" && make test`
Expected: all suites pass (the migration is additive; `ABSServerDAOTests` still passes here since Task 4 hasn't touched the DAO yet — `current()`/`save()` still exist unchanged in this task).

- [ ] **Step 7: Commit**

```bash
cd "/Users/dfakkeldy/Developer/Echo/.claude/worktrees/happy-hertz-be98c1"
git add Shared/Database/Migrations/Schema_V31.swift Shared/Database/DatabaseService.swift EchoTests/SchemaV31Tests.swift
git commit -m "feat(db): add Schema_V31 multi-row abs_server migration

Adds an is_active flag and backfills any existing connected server as
active, laying the groundwork for macOS's multiple-saved-servers UI
without disrupting iOS's single-active-server semantics."
```

---

### Task 4: ABSServerDAO multi-server API

**Files:**
- Modify: `Shared/Database/DAOs/ABSServerDAO.swift` (full rewrite)
- Modify: `EchoCore/ViewModels/PlayerModel+Audiobookshelf.swift:48-54` (iOS call site)
- Modify: `Echo macOS/Views/MacAudiobookshelfView.swift:119-128` (macOS call site — minimal fix only; the full Saved Servers UI is Task 5)
- Test: `EchoTests/ABSServerDAOTests.swift` (full rewrite — the existing `saveReplacesPreviousCurrentServerRecord` test exercises the removed `save()` method)

**Interfaces:**
- Consumes: `Schema_V31`'s `is_active` column (Task 3).
- Produces: `ABSServerRecord` gains `var isActive: Bool = false` and `Identifiable` conformance (consumed by Task 5's `ForEach(model.savedServers)`). `ABSServerDAO.current() throws -> ABSServerRecord?` (signature unchanged, semantics now "the active row"), `.all() throws -> [ABSServerRecord]`, `.upsert(_ server: ABSServerRecord) throws`, `.setActive(_ id: String) throws`, `.delete(_ id: String) throws` (unchanged) — `all()`/`upsert`/`setActive` consumed by Task 5.

- [ ] **Step 1: Write the failing DAO tests**

Replace the full contents of `EchoTests/ABSServerDAOTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct ABSServerDAOTests {
    private func makeRecord(id: String, addedAt: String) -> ABSServerRecord {
        ABSServerRecord(
            id: id,
            baseURL: "http://\(id).local:13378",
            username: "reader",
            defaultLibraryId: nil,
            addedAt: addedAt)
    }

    @Test func upsertInsertsNewServerWithoutActivatingIt() throws {
        let database = try DatabaseService(inMemory: ())
        let dao = ABSServerDAO(db: database.writer)
        try dao.upsert(makeRecord(id: "server-one", addedAt: "2026-06-28T00:00:00Z"))

        #expect(try dao.current() == nil)
        #expect(try dao.all().map(\.id) == ["server-one"])
    }

    @Test func setActiveExclusivelyActivatesOneServer() throws {
        let database = try DatabaseService(inMemory: ())
        let dao = ABSServerDAO(db: database.writer)
        try dao.upsert(makeRecord(id: "server-one", addedAt: "2026-06-28T00:00:00Z"))
        try dao.upsert(makeRecord(id: "server-two", addedAt: "2026-06-28T01:00:00Z"))
        try dao.setActive("server-one")

        try dao.setActive("server-two")

        let current = try #require(try dao.current())
        #expect(current.id == "server-two")
        let activeCount = try database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM abs_server WHERE is_active = 1") ?? 0
        }
        #expect(activeCount == 1)
    }

    @Test func allReturnsEverySavedServerNewestFirst() throws {
        let database = try DatabaseService(inMemory: ())
        let dao = ABSServerDAO(db: database.writer)
        try dao.upsert(makeRecord(id: "server-old", addedAt: "2026-06-28T00:00:00Z"))
        try dao.upsert(makeRecord(id: "server-new", addedAt: "2026-06-28T01:00:00Z"))

        #expect(try dao.all().map(\.id) == ["server-new", "server-old"])
    }

    @Test func deleteRemovesOnlyTheTargetedServer() throws {
        let database = try DatabaseService(inMemory: ())
        let dao = ABSServerDAO(db: database.writer)
        try dao.upsert(makeRecord(id: "server-one", addedAt: "2026-06-28T00:00:00Z"))
        try dao.upsert(makeRecord(id: "server-two", addedAt: "2026-06-28T01:00:00Z"))

        try dao.delete("server-one")

        #expect(try dao.all().map(\.id) == ["server-two"])
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd "/Users/dfakkeldy/Developer/Echo/.claude/worktrees/happy-hertz-be98c1" && make build-tests`
Expected: build FAILS — `upsert`/`setActive`/`all` don't exist on `ABSServerDAO` yet.

- [ ] **Step 3: Rewrite `Shared/Database/DAOs/ABSServerDAO.swift`**

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

struct ABSServerRecord: Codable, FetchableRecord, MutablePersistableRecord, Identifiable {
    var id: String
    var baseURL: String
    var username: String
    var defaultLibraryId: String?
    var addedAt: String
    var isActive: Bool = false

    static let databaseTableName = "abs_server"

    enum CodingKeys: String, CodingKey {
        case id, username
        case baseURL = "base_url"
        case defaultLibraryId = "default_library_id"
        case addedAt = "added_at"
        case isActive = "is_active"
    }

    var isPlainHTTP: Bool {
        URL(string: baseURL)?.scheme?.localizedCaseInsensitiveCompare("http") == .orderedSame
    }
}

/// Multiple servers can be saved (v2: `Schema_V31`); exactly one is active at
/// a time. `current()` returns the active row — iOS's single-server flow only
/// ever activates one, so its call sites are unaffected by the schema change.
struct ABSServerDAO {
    let db: DatabaseWriter

    /// The active server, if any.
    func current() throws -> ABSServerRecord? {
        try db.read { db in
            try ABSServerRecord.filter(Column("is_active") == true).fetchOne(db)
        }
    }

    /// Every saved server, most-recently-added first.
    func all() throws -> [ABSServerRecord] {
        try db.read { db in
            try ABSServerRecord.order(Column("added_at").desc).fetchAll(db)
        }
    }

    /// Insert-or-update by id. Does not change which server is active.
    func upsert(_ server: ABSServerRecord) throws {
        var copy = server
        try db.write { db in try copy.save(db) }
    }

    /// Marks `id` active and every other saved server inactive.
    func setActive(_ id: String) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE abs_server SET is_active = 0")
            try db.execute(sql: "UPDATE abs_server SET is_active = 1 WHERE id = ?", arguments: [id])
        }
    }

    func delete(_ id: String) throws {
        _ = try db.write { db in try ABSServerRecord.deleteOne(db, key: id) }
    }
}
```

- [ ] **Step 4: Fix the iOS call site in `PlayerModel+Audiobookshelf.swift`**

The `connectAudiobookshelf` method currently has:

```swift
        let record = ABSServerRecord(
            id: serverID, baseURL: baseURL.absoluteString, username: username,
            defaultLibraryId: defaultLib,
            addedAt: ISO8601DateFormatter().string(from: Date()))
        do {
            try dao.save(record)
        } catch {
```

Change to:

```swift
        let record = ABSServerRecord(
            id: serverID, baseURL: baseURL.absoluteString, username: username,
            defaultLibraryId: defaultLib,
            addedAt: ISO8601DateFormatter().string(from: Date()))
        do {
            try dao.upsert(record)
            try dao.setActive(serverID)
        } catch {
```

- [ ] **Step 5: Fix the macOS call site in `MacAudiobookshelfView.swift`**

In `attemptConnect`, this block currently reads:

```swift
            let record = ABSServerRecord(
                id: newServerID,
                baseURL: baseURL.absoluteString,
                username: username,
                defaultLibraryId: defaultLib,
                addedAt: Date().ISO8601Format())
            try ABSServerDAO(db: db.writer).save(record)
            service = svc
```

Change to:

```swift
            let record = ABSServerRecord(
                id: newServerID,
                baseURL: baseURL.absoluteString,
                username: username,
                defaultLibraryId: defaultLib,
                addedAt: Date().ISO8601Format())
            let dao = ABSServerDAO(db: db.writer)
            try dao.upsert(record)
            try dao.setActive(newServerID)
            service = svc
```

(This is the minimal fix to keep `Echo macOS` compiling against the new DAO API. Task 5 builds the full Saved Servers feature on top of this.)

- [ ] **Step 6: Run the tests to verify they pass**

Run: `cd "/Users/dfakkeldy/Developer/Echo/.claude/worktrees/happy-hertz-be98c1" && make build-tests && make test-only FILTER=EchoTests/ABSServerDAOTests`
Expected: PASS (all 4 tests).

- [ ] **Step 7: Run the full iOS test suite, then build `Echo macOS`, sequentially**

```bash
cd "/Users/dfakkeldy/Developer/Echo/.claude/worktrees/happy-hertz-be98c1"
make test
```
Expected: all suites pass (in particular, `AudiobookshelfServiceAuthTests` and anything exercising `connectAudiobookshelf` — confirm no other test references the removed `save(`).
```bash
cd "/Users/dfakkeldy/Developer/Echo/.claude/worktrees/happy-hertz-be98c1"
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && xcodebuild build -scheme "Echo macOS" -destination 'platform=macOS' -jobs 4 CODE_SIGNING_ALLOWED=NO
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 8: Commit**

```bash
cd "/Users/dfakkeldy/Developer/Echo/.claude/worktrees/happy-hertz-be98c1"
git add Shared/Database/DAOs/ABSServerDAO.swift EchoCore/ViewModels/PlayerModel+Audiobookshelf.swift "Echo macOS/Views/MacAudiobookshelfView.swift" EchoTests/ABSServerDAOTests.swift
git commit -m "feat(abs): replace ABSServerDAO.save() with multi-server upsert/setActive/all

ABSServerRecord gains is_active + Identifiable. current() keeps meaning
'the active server' so iOS's single-server flow is unaffected. Both
existing save() call sites (iOS connect, macOS attemptConnect) move to
upsert + setActive; the macOS Saved Servers UI itself is the next commit."
```

---

### Task 5: macOS Saved Servers UI

**Files:**
- Modify: `Echo macOS/Views/MacAudiobookshelfView.swift` (view model + view)
- Test: `EchoTests/MacAudiobookshelfParityTests.swift` (append)

**Interfaces:**
- Consumes: `ABSServerDAO.all()`, `.setActive(_:)`, `.upsert(_:)` (Task 4). `ABSTokenStore(serverID:).clear()` (pre-existing).
- Produces: nothing consumed by later tasks (this is the final feature task; Task 6 is push/PR only).

- [ ] **Step 1: Write the failing structural test**

Append to `EchoTests/MacAudiobookshelfParityTests.swift`, before the struct's closing `}`:

```swift
    @Test func supportsMultipleSavedServers() throws {
        let src = try MacSource.read("Views/MacAudiobookshelfView.swift")
        #expect(
            src.contains("case addingServer"),
            "Phase must support adding another server without losing the active connection.")
        #expect(
            src.contains("func switchTo(") && src.contains(".setActive("),
            "Switching servers must mark the chosen one active via the shared DAO.")
        #expect(
            src.contains("func removeSavedServer(") && src.contains("ABSTokenStore(serverID:"),
            "Removing a saved server must clear its Keychain tokens.")
        #expect(
            src.contains("savedServers") && src.contains(".all()"),
            "The saved-servers list must be loaded via the shared DAO's all().")
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd "/Users/dfakkeldy/Developer/Echo/.claude/worktrees/happy-hertz-be98c1" && make test-only FILTER=EchoTests/MacAudiobookshelfParityTests`
Expected: FAIL on `supportsMultipleSavedServers` — none of the marker strings exist yet.

- [ ] **Step 3: Add the `.addingServer` phase and `savedServers` state**

In `Echo macOS/Views/MacAudiobookshelfView.swift`, change:

```swift
    enum Phase { case disconnected, connecting, connected }

    var phase: Phase = .disconnected
    var server: ABSServerRecord?
    var errorMessage: String?
```

to:

```swift
    enum Phase { case disconnected, connecting, connected, addingServer }

    var phase: Phase = .disconnected
    var server: ABSServerRecord?
    var savedServers: [ABSServerRecord] = []
    var errorMessage: String?
```

- [ ] **Step 4: Update `load()` and add `loadSavedServers()`**

Change:

```swift
    func load() async {
        guard let record = try? ABSServerDAO(db: db.writer).current() else {
            phase = .disconnected
            return
        }
        server = record
        serverID = record.id
        service = makeService(for: record)
        phase = .connected
        await loadLibraries()
    }
```

to:

```swift
    func load() async {
        loadSavedServers()
        guard let record = try? ABSServerDAO(db: db.writer).current() else {
            phase = .disconnected
            return
        }
        server = record
        serverID = record.id
        service = makeService(for: record)
        phase = .connected
        await loadLibraries()
    }

    private func loadSavedServers() {
        savedServers = (try? ABSServerDAO(db: db.writer).all()) ?? []
    }
```

- [ ] **Step 5: Update `attemptConnect`'s failure-phase fallback and success path**

`attemptConnect` (after Task 4's fix) currently ends its success path with:

```swift
            let dao = ABSServerDAO(db: db.writer)
            try dao.upsert(record)
            try dao.setActive(newServerID)
            service = svc
            serverID = newServerID
            server = record
            password = ""
            phase = .connected
            await loadLibraries()
        } catch let absError as ABSError {
            svc.invalidate()
            phase = .disconnected
            if case .untrustedCertificate(let h, let sha) = absError {
                pendingCert = PendingCert(host: h, sha256: sha)
            } else {
                errorMessage = absError.errorDescription ?? "Could not connect to the server."
            }
        } catch {
            svc.invalidate()
            phase = .disconnected
            errorMessage = error.localizedDescription
        }
```

Change to (adds `loadSavedServers()` on success, and fixes the failure-phase fallback so failing to add a *second* server doesn't masquerade as losing the still-active first one):

```swift
            let dao = ABSServerDAO(db: db.writer)
            try dao.upsert(record)
            try dao.setActive(newServerID)
            service?.invalidate()
            service = svc
            serverID = newServerID
            server = record
            password = ""
            phase = .connected
            loadSavedServers()
            await loadLibraries()
        } catch let absError as ABSError {
            svc.invalidate()
            phase = server != nil ? .connected : .disconnected
            if case .untrustedCertificate(let h, let sha) = absError {
                pendingCert = PendingCert(host: h, sha256: sha)
            } else {
                errorMessage = absError.errorDescription ?? "Could not connect to the server."
            }
        } catch {
            svc.invalidate()
            phase = server != nil ? .connected : .disconnected
            errorMessage = error.localizedDescription
        }
```

- [ ] **Step 6: Replace `disconnect()` and add `switchTo`/`removeSavedServer`/`beginAddingServer`/`cancelAddingServer`**

Change:

```swift
    func disconnect() async {
        if let svc = service {
            _ = await svc.signOut()
            svc.invalidate()
        }
        if let sid = serverID { ABSTokenStore(serverID: sid).clear() }
        if let record = server { try? ABSServerDAO(db: db.writer).delete(record.id) }
        service = nil
        serverID = nil
        server = nil
        libraries = []
        items = []
        selectedLibraryID = nil
        phase = .disconnected
    }
```

to:

```swift
    func disconnect() async {
        guard let current = server else { return }
        await removeSavedServer(current)
    }

    func beginAddingServer() {
        errorMessage = nil
        serverURLText = ""
        username = ""
        password = ""
        phase = .addingServer
    }

    func cancelAddingServer() {
        errorMessage = nil
        phase = server != nil ? .connected : .disconnected
    }

    /// Switches the active server to an already-saved one. Does not touch
    /// Keychain tokens — the saved refresh token is reused, so no re-login
    /// is needed.
    func switchTo(_ saved: ABSServerRecord) async {
        errorMessage = nil
        service?.invalidate()
        guard let newService = makeService(for: saved) else {
            errorMessage = "Could not reconnect to this server."
            return
        }
        do {
            try ABSServerDAO(db: db.writer).setActive(saved.id)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        service = newService
        serverID = saved.id
        server = saved
        selectedLibraryID = nil
        phase = .connected
        loadSavedServers()
        await loadLibraries()
    }

    /// Removes a saved server: best-effort remote sign-out if it was the
    /// active one, clears its Keychain tokens, deletes its DB row. Mirrors
    /// the old `disconnect()` but targets a specific server.
    func removeSavedServer(_ saved: ABSServerRecord) async {
        let wasActive = saved.id == serverID
        if wasActive, let svc = service {
            _ = await svc.signOut()
            svc.invalidate()
        }
        ABSTokenStore(serverID: saved.id).clear()
        try? ABSServerDAO(db: db.writer).delete(saved.id)
        loadSavedServers()
        guard wasActive else { return }
        service = nil
        serverID = nil
        server = nil
        libraries = []
        items = []
        selectedLibraryID = nil
        phase = .disconnected
    }
```

- [ ] **Step 7: Add `Identifiable`-driven UI — header, connect form, body switch**

Change the `header` computed property:

```swift
    private var header: some View {
        HStack {
            Text("Audiobookshelf").font(.headline)
            Spacer()
            if model.phase == .connected, let server = model.server {
                Text(server.username).foregroundStyle(.secondary)
                Button("Sign Out") { Task { await model.disconnect() } }
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }
```

to:

```swift
    private var header: some View {
        HStack {
            Text("Audiobookshelf").font(.headline)
            Spacer()
            if model.phase == .connected, let server = model.server {
                Text(server.username).foregroundStyle(.secondary)
                if model.savedServers.count > 1 {
                    Button("Switch Server…") { model.beginAddingServer() }
                }
                Button("Sign Out") { Task { await model.disconnect() } }
            }
            if model.phase == .addingServer {
                Button("Cancel") { model.cancelAddingServer() }
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }
```

Change the `body`'s phase switch:

```swift
            switch model.phase {
            case .disconnected: connectForm
            case .connecting:
                ProgressView("Connecting…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .connected: browse
            }
```

to:

```swift
            switch model.phase {
            case .disconnected, .addingServer: connectForm
            case .connecting:
                ProgressView("Connecting…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .connected: browse
            }
```

Change `connectForm` to show saved servers first:

```swift
    private var connectForm: some View {
        Form {
            Section {
                TextField(
                    "Server URL", text: $model.serverURLText, prompt: Text("https://host:13378")
                )
                .textContentType(.URL)
                TextField("Username", text: $model.username)
                SecureField("Password", text: $model.password)
            } footer: {
                if let error = model.errorMessage {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
            }
            Button("Connect") { Task { await model.connect() } }
                .buttonStyle(.borderedProminent)
                .disabled(model.serverURLText.isEmpty || model.username.isEmpty)
        }
        .formStyle(.grouped)
    }
```

to:

```swift
    private var connectForm: some View {
        Form {
            if !model.savedServers.isEmpty {
                Section("Saved Servers") {
                    ForEach(model.savedServers) { saved in
                        savedServerRow(saved)
                    }
                }
            }
            Section {
                TextField(
                    "Server URL", text: $model.serverURLText, prompt: Text("https://host:13378")
                )
                .textContentType(.URL)
                TextField("Username", text: $model.username)
                SecureField("Password", text: $model.password)
            } footer: {
                if let error = model.errorMessage {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
            }
            Button("Connect") { Task { await model.connect() } }
                .buttonStyle(.borderedProminent)
                .disabled(model.serverURLText.isEmpty || model.username.isEmpty)
        }
        .formStyle(.grouped)
    }

    private func savedServerRow(_ saved: ABSServerRecord) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(saved.username).fontWeight(saved.isActive ? .semibold : .regular)
                Text(URL(string: saved.baseURL)?.host ?? saved.baseURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if saved.isActive {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Connect") { Task { await model.switchTo(saved) } }
                    .controlSize(.small)
            }
            Button(role: .destructive) {
                Task { await model.removeSavedServer(saved) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }
```

- [ ] **Step 8: Run the test to verify it passes**

Run: `cd "/Users/dfakkeldy/Developer/Echo/.claude/worktrees/happy-hertz-be98c1" && make test-only FILTER=EchoTests/MacAudiobookshelfParityTests`
Expected: PASS (all 6 tests in the suite — 3 pre-existing + Tasks 1/2/5's additions).

- [ ] **Step 9: Build `Echo macOS` and run the full iOS suite, sequentially**

```bash
cd "/Users/dfakkeldy/Developer/Echo/.claude/worktrees/happy-hertz-be98c1"
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && xcodebuild build -scheme "Echo macOS" -destination 'platform=macOS' -jobs 4 CODE_SIGNING_ALLOWED=NO
```
Expected: `** BUILD SUCCEEDED **`.
```bash
cd "/Users/dfakkeldy/Developer/Echo/.claude/worktrees/happy-hertz-be98c1"
make test
```
Expected: all suites pass.

- [ ] **Step 10: Commit**

```bash
cd "/Users/dfakkeldy/Developer/Echo/.claude/worktrees/happy-hertz-be98c1"
git add "Echo macOS/Views/MacAudiobookshelfView.swift" EchoTests/MacAudiobookshelfParityTests.swift
git commit -m "feat(macos): add Saved Servers list to the Audiobookshelf sheet

Switch/Add/Remove over the new multi-server DAO API. Removing a saved
server clears its Keychain tokens; switching reuses the saved refresh
token (no re-login). Completes slice 2 of the deferred ABS macOS
parity work."
```

---

### Task 6: Push and open the PR

**Files:** none (process only).

- [ ] **Step 1: Push the branch**

```bash
cd "/Users/dfakkeldy/Developer/Echo/.claude/worktrees/happy-hertz-be98c1"
git push -u origin claude/happy-hertz-be98c1
```

- [ ] **Step 2: Open the PR against `nightly`**

```bash
cd "/Users/dfakkeldy/Developer/Echo/.claude/worktrees/happy-hertz-be98c1"
gh pr create --base nightly --title "feat(abs): macOS two-way progress sync + multiple saved servers" --body "$(cat <<'EOF'
## Summary
- Two-way ABS playback-progress sync on macOS (`MacPlayerModel+Audiobookshelf.swift`), mirroring iOS's `PlayerModel+Audiobookshelf.swift` over the shared `ABSProgressSync`/`ABSProgressReconciler` helpers. Known gap: no multi-m4b book-time axis on macOS yet (tracked separately).
- Multiple saved ABS servers with credentials: `Schema_V31` converts `abs_server` into a real multi-row table (`is_active` flag); `ABSServerDAO` gains `all()`/`setActive(id:)`/`upsert(_:)`, replacing `save()`. macOS gets a Saved Servers list (switch/add/remove) in the existing Connect sheet; iOS is unaffected (still single-active-server).

Design: docs/superpowers/specs/2026-06-30-abs-macos-progress-sync-multi-server-design.md
Plan: docs/superpowers/plans/2026-06-30-abs-macos-progress-sync-multi-server.md

## Test plan
- [x] `make test` (full iOS/EchoTests suite, including new `SchemaV31Tests`, rewritten `ABSServerDAOTests`, extended `MacAudiobookshelfParityTests`)
- [x] `xcodebuild build -scheme "Echo macOS"` after every commit
- [ ] Owner on-device verify: connect two ABS servers, switch between them, confirm progress round-trips with an iOS device on the same library item
EOF
)"
```

- [ ] **Step 3: Check CI**

```bash
cd "/Users/dfakkeldy/Developer/Echo/.claude/worktrees/happy-hertz-be98c1"
gh pr checks --watch
```

If any check fails, inspect the failing job's logs, fix the concrete blocker, push again, and re-check until CI is green or blocked for a clearly external reason.

## Self-Review

**Spec coverage:** Slice 1 (state, sync engine file, 6 hook points) → Tasks 1–2. Slice 2 (`Schema_V31`, DAO rewrite, both call-site fixes, Saved Servers UI) → Tasks 3–5. Testing section → structural tests in Tasks 1/2/5, migration test in Task 3, DAO tests in Task 4. Verification/rollout section → build+test steps in every task, push/PR/CI in Task 6. No spec section is uncovered.

**Placeholder scan:** no TBD/TODO; every step has complete code or an exact command with expected output.

**Type consistency:** `ABSServerRecord.isActive` (Task 4) matches `saved.isActive` (Task 5) and the `is_active` SQL/Schema_V31 column (Task 3) throughout. `MacPlayerModel.absServerDAO`/`makeAudiobookshelfService()`/`invalidateAudiobookshelfServiceCache()`/`refreshABSSyncIdentity()`/`maybePushABSProgress(force:)`/`reconcileABSProgressOnLoad()` (Task 1) are referenced with identical names and signatures in Task 2's hook wiring. `MacAudiobookshelfViewModel.switchTo(_:)`/`removeSavedServer(_:)`/`beginAddingServer()`/`cancelAddingServer()`/`loadSavedServers()`/`savedServers` (Task 5) are self-consistent within that task — no other task references them.

One found gap, fixed inline before finalizing: Task 4's macOS call-site fix had to be split out from Task 5's UI work, because removing `ABSServerDAO.save()` would otherwise leave `Echo macOS` non-compiling between those two tasks.
