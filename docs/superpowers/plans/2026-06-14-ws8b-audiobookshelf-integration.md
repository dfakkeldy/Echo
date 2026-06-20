# WS8b — Audiobookshelf Integration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Connect a self-hosted Audiobookshelf (ABS) server as a first-class library source so a self-hosted collection downloads into Echo's existing local study pipeline — alignment, phrase search, EPUB sync, and flashcards all keep working unchanged.

**Architecture:** Download-to-local, **not** streaming. A new concrete `AudiobookshelfService` (sibling to `CloudKitSyncService`) speaks the ABS HTTP API. Downloaded audio + any bundled EPUB land in an app-owned folder `Application Support/ABSLibrary/{remoteItemID}/`; that folder is then handed to the **unchanged** `PlayerLoadingCoordinator.loadFolder`, whose post-load scan auto-discovers the sibling `.epub`. A book's identity stays `folderURL.absoluteString`; ABS provenance is stamped onto `AudiobookRecord` (new columns). Two-way playback-progress sync wires into the existing `coordinator_saveProgress` / restore-on-load seams, with ABS authoritative for ABS-backed books.

**Tech Stack:** Swift 6 / SwiftUI, GRDB (SQLite), `URLSession` async/await, Keychain (via `KeychainStore`), ZIPFoundation (already vendored), Swift Testing (`import Testing`), `DatabaseService(inMemory:)`.

---

## ⚠️ Reconciliation (2026-06-20) — read this first; it overrides stale text below

This plan was written 2026-06-14. Four migrations have shipped since, and some Milestone A scaffolding already exists. **Where this banner and the body disagree, the banner wins.**

1. **Migration head is now V21** (`v17_track_narration_voice`, `v18_abs_server`, `v19_word_timing`, `v20_batch_queue`, `v21_batch_kind`). So:
   - **Milestone A's `abs_server` migration (V18) already SHIPPED.** Task A1 is **DONE** — do not recreate `Schema_V18.swift`, `ABSServerDAO.swift`, the V18 registration, or `SchemaV18Tests.swift`. Verify they exist and pass, then move on.
   - **Milestone B's `audiobook` provenance migration is `V22`, NOT `V19`.** Everywhere the body says `V19` / `Schema_V19` / `SchemaV19Tests` / `v19_audiobook_abs_provenance` **for the four audiobook provenance columns** (`source_type`, `server_id`, `remote_item_id`, `topics_json`), read **`V22` / `Schema_V22` / `SchemaV22Tests` / `v22_audiobook_abs_provenance`**. (`V19` in the live schema is `word_timing` — a different, already-shipped migration.)

2. **Existing Milestone A scaffolding must be HARDENED/COMPLETED, not recreated.** These files already exist:
   - `EchoCore/Services/Audiobookshelf/ABSModels.swift` — **richer than the body's version** (full metadata, tracks, chapters, progress response). **Keep it.** Required fix: `ABSLoginResponse.user` only decodes `id`, so JWT login cannot read tokens — add `accessToken` / `refreshToken` (and a legacy permanent `token` fallback for pre-2.26 servers) plus the `access`/`refresh` convenience accessors the service expects.
   - `EchoCore/Services/Audiobookshelf/ABSEndpoints.swift` — currently an `enum` of static methods using seven `URL(string:…)!` force-unwraps (**CODE_AUDIT Critical**). **Replace the shape with the body's injectable `struct ABSEndpoints { let baseURL: URL }`** using `.appending(path:)` / `URLComponents` (no force-unwraps). Update call sites accordingly.
   - `EchoCore/Services/Audiobookshelf/ABSTokenStore.swift` — exists; reconcile to the body's per-server (`service:`-namespaced) design from Task A2 and annotate `@MainActor` (Rec-3). Keep the refresh-in-Keychain / access-in-memory split.

3. **Subpath base URLs are supported.** The connected server may live under a reverse-proxy path prefix (e.g. `http://host:13378/audiobookshelf`), so the base URL is **not** guaranteed to be just `scheme://host:port`. `baseURL` must retain its full path; every endpoint appends to it with `.appending(path:)` (relative, no leading slash) — never reconstruct from host/port. The login/normalization step also defaults a missing scheme to `http` for bare `host:port` LAN/tailnet addresses.

4. **Pro gating: build UNGATED this pass.** PRICING.md marks downloads + background sync as Pro, but the paywall is a separate, later change. Do **not** add `isPro` checks at the download / sync entry points here.

5. **Live verification** happens at the end against the owner's real ABS server (owner-driven, like the narration device gates). All development + CI stays offline via `URLProtocolStub`. Credentials are never written to disk or committed.

6. **Reviewer gates unchanged but renumbered:** schema-migration-reviewer checks **V22** (not V19) for sibling-branch collisions; cross-platform-parity-reviewer runs after the `Shared/` DB + service changes (v1 UI is iOS-only by design).

---

## Scope & Decisions

This plan implements **ROADMAP.md Phase 9** tiers **9.1 → 9.4**. Tier **9.5 (streaming, bookmark round-trip, multi-server) is out of scope** — deferred post-1.0.

Four **milestones**, each producing working, testable software on its own (each could be a standalone plan — they are sequenced by dependency, not bundled by necessity):

| Milestone | Tier | Ships | Migration |
|-----------|------|-------|-----------|
| **A** | 9.1 | Connect to a server, browse libraries/items (read-only) | V18 (`abs_server`) — **SHIPPED** |
| **B** | 9.2 | Download a book → it plays through the existing pipeline (the MVP) | **V22** (`audiobook` provenance + topics) |
| **C** | 9.3 | Browse/search the ABS library by topic; carry topics onto import | — (uses V22) |
| **D** | 9.4 | Two-way playback-progress sync (ABS-authoritative) | — (sidecar field) |

**Migration numbering (corrected 2026-06-20 — see banner):** **A's V18 (`abs_server`) has shipped.** Since then V19 (`word_timing`), V20 (`batch_queue`), and V21 (`batch_kind`) shipped, so **B's `audiobook`-columns migration is now V22**, the next free number. The cross-platform-parity and schema-migration reviewer agents should confirm no V22 collision exists on sibling branches before merge (several `feat/v1-real/*` branches carry their own migrations).

**UI surface:** v1 UI (Connections settings, Browse, "Add from Audiobookshelf") is **iOS-only** (it lives in `EchoCore/Views/`, the iOS app's view layer). The `AudiobookshelfService` + DB layer live in `Shared/` + `EchoCore/Services/` so macOS can adopt the same service later (fast-follow, matches the single-server v1 decision). watchOS/Widget/CarPlay are unaffected — they read whatever local books exist.

**Why concrete types, no protocol:** Per CLAUDE.md and `CODE_AUDIT.md §10.1`, Echo uses concrete-type + constructor injection, unit-tested with real in-memory instances — **not** protocol/mock theater (an unused protocol abstraction was deleted in commit `4c77c35`). `AudiobookshelfService` takes a `URLSession` in its initializer; tests inject a `URLSession` backed by a stub `URLProtocol`. That is the test seam — no `ABSServiceProtocol`.

---

## File Structure

### New files

| File | Responsibility |
|------|----------------|
| `Shared/Database/Migrations/Schema_V18.swift` | Create `abs_server` table |
| `Shared/Database/Migrations/Schema_V19.swift` | Add `source_type`, `server_id`, `remote_item_id`, `topics_json` columns to `audiobook` |
| `Shared/Database/DAOs/ABSServerDAO.swift` | `ABSServerRecord` + CRUD for the single connected server |
| `EchoCore/Services/Audiobookshelf/ABSModels.swift` | `Codable` DTOs for the ABS API (login, libraries, items, progress) + the `ABSError` enum |
| `EchoCore/Services/Audiobookshelf/ABSEndpoints.swift` | All ABS URL/path construction in one place |
| `EchoCore/Services/Audiobookshelf/ABSTokenStore.swift` | Per-server access (memory) + refresh (Keychain) token storage |
| `EchoCore/Services/Audiobookshelf/AudiobookshelfService.swift` | The HTTP client: auth + refresh-with-rotation, libraries, items, cover, file download, progress |
| `EchoCore/Services/Audiobookshelf/ABSImportService.swift` | Orchestrates: pre-stamp record → download files → `loadFolder` |
| `EchoCore/Views/Settings/ABSConnectionsSettingsView.swift` | "Connections" settings sub-screen: add/login/status/sign-out |
| `EchoCore/Views/Audiobookshelf/ABSBrowseView.swift` | Libraries → items → item detail; "Add" action; topic search/filter |
| `EchoCore/Views/Audiobookshelf/ABSImportProgressView.swift` | Download progress overlay |
| `EchoTests/Support/URLProtocolStub.swift` | Test helper: canned HTTP responses for `URLSession` |
| `EchoTests/SchemaV18Tests.swift` … `EchoTests/SchemaV19Tests.swift` | Migration tests |
| `EchoTests/ABSTokenStoreTests.swift`, `EchoTests/AudiobookshelfServiceAuthTests.swift`, `EchoTests/AudiobookshelfServiceLibraryTests.swift`, `EchoTests/AudiobookshelfServiceDownloadTests.swift`, `EchoTests/ABSImportServiceTests.swift`, `EchoTests/AudiobookshelfServiceProgressTests.swift` | Unit tests |

### Modified files

| File | Change |
|------|--------|
| `Shared/Database/DatabaseService.swift:108` | Register V18 + V19 migrations |
| `Shared/Database/DAOs/AudiobookDAO.swift:48` | Add 4 columns to `AudiobookRecord` + `CodingKeys` (nil defaults) |
| `Shared/KeychainStore.swift:16` | Add `.absRefreshToken` to the `Key` enum |
| `Shared/FileLocations.swift` | Add `absLibraryDirectory(remoteItemID:)` helper |
| `EchoCore/Services/TimelineIngestionService.swift:22` | Carry over provenance columns on re-ingest |
| `EchoCore/Models/EchoPlaylistManifest.swift:21` | Add `updatedAt` (ms) to `ManifestPlaybackState` |
| `EchoCore/Views/SettingsView.swift:143` | Add a "Connections" `NavigationLink` section |
| `EchoCore/Views/PlaylistView.swift:472` | Add "Add from Audiobookshelf" button beside the `.fileImporter` |
| `EchoCore/ViewModels/PlayerModel.swift:843` | Wire ABS progress push into `coordinator_saveProgress` (Milestone D) |
| `EchoCore/Info.plist:47` | Add no background-mode change for B's foreground happy-path; add nothing until B6 |

---

## Testing Strategy

- **Networking is tested offline.** `AudiobookshelfService` takes a `URLSession` in its initializer. Production passes `.shared` (or a background session). Tests pass a `URLSession` configured with `URLProtocolStub` (Task A3), which returns canned `(Data, HTTPURLResponse)` per request — no live server, deterministic, fast.
- **DB is tested in-memory** via `DatabaseService(inMemory: ())`, which auto-runs all migrations. Migration tests assert via `PRAGMA table_info(...)` (mirrors `EchoTests/SchemaV17Tests.swift`).
- **Swift Testing**, not XCTest, for all new tests: `import Testing`, `@Suite`, `@Test`, `#expect`. `@MainActor`-annotate suites that touch `DatabaseService` (it is `@MainActor`).
- **Run loop:** `make build-tests` once, then `make test-only FILTER=EchoTests/<Suite>` per the project's edit→test loop. Never enable parallel testing (16 GB machine).

---

## Architecture Review (swift-architecture-skill)

Reviewed against the MVVM playbook. Echo is `@Observable` MVVM with `PlayerModel` as the app-level view model; this plan adds a proper Service/Repository layer (`AudiobookshelfService`, `ABSImportService`, DAOs) at the side-effect boundary. **Fit: MVVM (concrete-DI variant) — PASS.**

**Two correctness fixes — already folded into the tasks above:**
1. **Single cached service (Task A7).** `PlayerModel` owns ONE `AudiobookshelfService` per connected server. A fresh-per-call factory would discard the in-memory access token *and* break the per-instance refresh serialization from Task A5 (concurrent refreshes across instances → `/auth/refresh` self-invalidation, ABS #5253). Browse/import/progress all route through `makeAudiobookshelfService()`.
2. **Cancellable item loads (Task A8).** Browse uses `.task(id: selectedLibrary)` + `Task.checkCancellation()` so a slow older library response can't overwrite a newer selection (MVVM stale-async anti-pattern).

**Affirmed as correct:**
- **Concrete-type DI / injected `URLSession` seam** — the right call for Echo. The skill defaults to protocol DI, but CLAUDE.md (and `CODE_AUDIT.md §10.1`, commit `4c77c35`) explicitly forbids unused protocol abstractions; the `URLProtocolStub`-backed `URLSession` is a *better* seam because it exercises the real request-building + decoding path. User convention overrides the skill default.
- **Off-main decoding** via the `nonisolated static` transport (`@MainActor` service, but `JSONDecoder` runs off-actor) — avoids the "heavy work on main actor" anti-pattern.
- **`prepareLocalFolder → loadFolder` separation** — side-effecting orchestration in `ABSImportService` (unit-testable), fire-and-forget pipeline call in the VM. Clean dependency direction (View → PlayerModel → ABSImportService/AudiobookshelfService → URLSession/DAOs).
- **GRDB migration layering** — ordered V18/V19, one-test-per-version, with the `TimelineIngestionService` carry-over guarding the upsert-wipe.

**Optional follow-ups (not blocking; note in PR if deferred):**
- **Rec-1:** Give the Browse screen a dedicated `@Observable ABSBrowseModel` with a `Loadable<[ABSLibraryItem]>` state enum. The screen carries enough async state (libraries + items + loading + error + search) to justify lifting service calls out of the View — stricter MVVM and more testable than the current view-driven `.task`. (The Connections settings screen can stay view-driven; it matches the existing `ProTranscriptsSettingsView` house style.)
- **Rec-2:** In `maybePushABSProgress`, cache the current book's `(sourceType, remoteItemID)` when the book loads instead of a `AudiobookDAO.get` on every save tick.
- **Rec-3:** Verify `ABSTokenStore` under Swift 6 strict concurrency; since all production access is main-actor, annotating it `@MainActor` is the cleanest way to satisfy `Sendable` capture checks in the refresh `Task`.

## SwiftUI Review (swiftui-expert-skill)

Reviewed against the SwiftUI correctness checklist + Topic Router (state-management, view-structure, image-optimization, list-patterns, latest-apis). **No correctness-checklist violations. PASS.**

**One fix — already folded in (Task A7):** `makeAudiobookshelfService()` now returns the warm cache *before* any DB read, because the Browse cover builder calls it per-row per diff — otherwise every cover render is a SQLite hit. Now it's a dictionary lookup.

**Affirmed sound:**
- **State ownership** — all `@State` is `private`; `@Environment(PlayerModel.self)` is the correct injected-`@Observable` access; no passed-in value is mis-declared as `@State`/`@StateObject`.
- **Sheet binding** — `.sheet(isPresented: $model.showingABSBrowse)` rides the same `@Bindable`-shadowed `model` PlaylistView already uses for `$model.showingDocumentImporter`; confirm PlaylistView has `@Bindable var model = model` (or equivalent) in scope where the sheet is attached.
- **Lists** — `ForEach(items)` / `ForEach(libraries)` use stable `Identifiable` ids (never `.indices`); constant view count per element; `Picker` selection of `ABSLibrary?` with `.tag(Optional(lib))` requires `ABSLibrary: Hashable` (added in A8).
- **Cancellation** — `.task(id: selectedLibrary)` is the right tool (auto-cancels the prior item load); paired with `Task.checkCancellation()`.
- **APIs current** — `NavigationStack`, `ContentUnavailableView`, `.searchable`, `AsyncImage`, `ProgressView(value:)`, `Form`, `LabeledContent` — all iOS 17–26, none deprecated. No `NavigationView`.
- **Progress UI** — `progress?(_:)` is invoked from `@MainActor ABSImportService`, so `importProgress = $0` mutates state on the main actor. Correct.

**Optional SwiftUI follow-ups (not blocking):**
- **SU-1 (UX):** On successful import, dismiss the *entire* Browse sheet (not just the `NavigationStack` detail level) so the user lands on the now-loaded player. Thread an `onImported: () -> Void` callback from `ABSBrowseView` into `ABSItemDetailView`, or bind the sheet's `isPresented` down. Current `dismiss()` only pops the detail.
- **SU-2 (perf, optional):** `AsyncImage` does not cache aggressively; covers are only 44×44 so it's fine for v1, but a large library scrolled fast re-fetches. If it shows up in a trace, swap to a small cached loader (see image-optimization reference) — measure first, don't pre-optimize.
- **SU-3:** If Rec-1's `ABSBrowseModel` is adopted, model its load state as `Loadable<[ABSLibraryItem]>` rather than `isLoading`/`errorMessage` bools — more expressive and removes the ambiguous "loading-and-errored" combination.

---

# Milestone A — Foundation: connect & browse (Tier 9.1)

**Outcome:** From Settings → Connections, the user adds one ABS server (URL + username + password), logs in (JWT obtained, refresh token persisted to Keychain), and browses libraries → items → item detail with covers. Read-only — no downloads yet.

---

### Task A1: `abs_server` table + migration V18

**Files:**
- Create: `Shared/Database/Migrations/Schema_V18.swift`
- Create: `Shared/Database/DAOs/ABSServerDAO.swift`
- Modify: `Shared/Database/DatabaseService.swift:108`
- Test: `EchoTests/SchemaV18Tests.swift`

- [ ] **Step 1: Write the failing migration test**

Create `EchoTests/SchemaV18Tests.swift` (mirror of `SchemaV17Tests.swift`):

```swift
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct SchemaV18Tests {
    @Test func v18CreatesAbsServerTable() throws {
        let db = try DatabaseService(inMemory: ())
        let columns = Set(
            try db.read { db in
                try Row.fetchAll(db, sql: "PRAGMA table_info(abs_server)").map {
                    $0["name"] as? String ?? ""
                }
            })
        #expect(columns.contains("id"))
        #expect(columns.contains("base_url"))
        #expect(columns.contains("username"))
        #expect(columns.contains("default_library_id"))
    }
}
```

- [ ] **Step 2: Run it to confirm it fails**

Run: `make build-tests && make test-only FILTER=EchoTests/SchemaV18Tests`
Expected: FAIL — `no such table: abs_server` (V18 not yet registered).

- [ ] **Step 3: Create the migration**

Create `Shared/Database/Migrations/Schema_V18.swift` (mirror `Schema_V16`'s `db.create(table:)` shape):

```swift
import GRDB

/// V18 — Audiobookshelf: the single connected server's non-secret identity.
/// Tokens are NEVER stored here; the refresh token lives in the Keychain
/// (see `ABSTokenStore`). One row for v1; multi-server is post-1.0.
enum Schema_V18 {
    nonisolated static func migrate(_ db: Database) throws {
        try db.create(table: "abs_server") { t in
            t.column("id", .text).primaryKey()           // stable server UUID we mint
            t.column("base_url", .text).notNull()        // e.g. http://host:13378
            t.column("username", .text).notNull()
            t.column("default_library_id", .text)        // from login response, optional
            t.column("added_at", .text).notNull()
        }
    }
}
```

- [ ] **Step 4: Register the migration**

In `Shared/Database/DatabaseService.swift`, immediately after the V17 line (`migrator.registerMigration("v17_track_narration_voice") { db in try Schema_V17.migrate(db) }`), add:

```swift
        migrator.registerMigration("v18_abs_server") { db in try Schema_V18.migrate(db) }
```

- [ ] **Step 5: Add the record + DAO**

Create `Shared/Database/DAOs/ABSServerDAO.swift` (mirror `AudiobookDAO`):

```swift
import Foundation
import GRDB

struct ABSServerRecord: Codable, FetchableRecord, MutablePersistableRecord {
    var id: String
    var baseURL: String
    var username: String
    var defaultLibraryId: String?
    var addedAt: String

    static let databaseTableName = "abs_server"

    enum CodingKeys: String, CodingKey {
        case id, username
        case baseURL = "base_url"
        case defaultLibraryId = "default_library_id"
        case addedAt = "added_at"
    }
}

struct ABSServerDAO {
    let db: DatabaseWriter

    /// v1 connects to at most one server; `current` returns it (or nil).
    func current() throws -> ABSServerRecord? {
        try db.read { db in try ABSServerRecord.fetchOne(db) }
    }

    func save(_ server: ABSServerRecord) throws {
        var copy = server
        try db.write { db in try copy.save(db) }
    }

    func delete(_ id: String) throws {
        _ = try db.write { db in try ABSServerRecord.deleteOne(db, key: id) }
    }
}
```

- [ ] **Step 6: Run the test to confirm it passes**

Run: `make test-only FILTER=EchoTests/SchemaV18Tests`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Shared/Database/Migrations/Schema_V18.swift Shared/Database/DAOs/ABSServerDAO.swift Shared/Database/DatabaseService.swift EchoTests/SchemaV18Tests.swift
git commit -m "feat(abs): add abs_server table (migration v18) + ABSServerDAO"
```

---

### Task A2: `ABSTokenStore` — refresh token in Keychain, access token in memory

**Files:**
- Modify: `Shared/KeychainStore.swift:16`
- Create: `EchoCore/Services/Audiobookshelf/ABSTokenStore.swift`
- Test: `EchoTests/ABSTokenStoreTests.swift`

**Why this split:** the access token is short-lived (1 h) — keep it in memory and refresh on demand. The refresh token is long-lived and sensitive — persist it in the Keychain (per the existing `KeychainStore` pattern), namespaced per server via the `service:` parameter so multi-server is a clean future extension.

- [ ] **Step 1: Add the Keychain key**

In `Shared/KeychainStore.swift`, extend the `Key` enum:

```swift
    enum Key: String {
        case securityScopedBookmark
        case bookmarkNotes
        case absRefreshToken   // Audiobookshelf rotating refresh token (per-server via `service:`)
    }
```

- [ ] **Step 2: Write the failing test**

Create `EchoTests/ABSTokenStoreTests.swift`:

```swift
import Testing

@testable import Echo

@Suite struct ABSTokenStoreTests {
    private func makeStore() -> ABSTokenStore {
        // Unique serverID per run avoids cross-test Keychain bleed.
        ABSTokenStore(serverID: "test-\(UUID().uuidString)")
    }

    @Test func persistsAndReadsRefreshToken() {
        let store = makeStore()
        store.refreshToken = "refresh-abc"
        #expect(store.refreshToken == "refresh-abc")
        store.clear()
        #expect(store.refreshToken == nil)
    }

    @Test func accessTokenIsMemoryOnly() {
        let store = makeStore()
        store.accessToken = "access-xyz"
        #expect(store.accessToken == "access-xyz")
        // A fresh store for the same server does NOT see the in-memory access token.
        let reopened = ABSTokenStore(serverID: store.serverID)
        #expect(reopened.accessToken == nil)
        store.clear()
    }
}
```

- [ ] **Step 3: Run it to confirm it fails**

Run: `make build-tests && make test-only FILTER=EchoTests/ABSTokenStoreTests`
Expected: FAIL — `cannot find 'ABSTokenStore' in scope`.

- [ ] **Step 4: Implement `ABSTokenStore`**

Create `EchoCore/Services/Audiobookshelf/ABSTokenStore.swift`:

```swift
import Foundation

/// Per-server token storage for Audiobookshelf.
/// - `accessToken`: short-lived JWT, memory-only (lost on relaunch; re-minted via refresh).
/// - `refreshToken`: long-lived, persisted in the Keychain, namespaced per server.
final class ABSTokenStore {
    let serverID: String
    private let service: String

    init(serverID: String) {
        self.serverID = serverID
        self.service = "com.echo.abs.\(serverID)"
    }

    /// In-memory only. Not persisted.
    var accessToken: String?

    var refreshToken: String? {
        get {
            KeychainStore.data(for: .absRefreshToken, service: service)
                .flatMap { String(data: $0, encoding: .utf8) }
        }
        set {
            if let token = newValue, let data = token.data(using: .utf8) {
                KeychainStore.set(data, for: .absRefreshToken, service: service)
            } else {
                KeychainStore.remove(.absRefreshToken, service: service)
            }
        }
    }

    func clear() {
        accessToken = nil
        KeychainStore.remove(.absRefreshToken, service: service)
    }
}
```

- [ ] **Step 5: Run the test to confirm it passes**

Run: `make test-only FILTER=EchoTests/ABSTokenStoreTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Shared/KeychainStore.swift EchoCore/Services/Audiobookshelf/ABSTokenStore.swift EchoTests/ABSTokenStoreTests.swift
git commit -m "feat(abs): add ABSTokenStore (refresh token in Keychain, access in memory)"
```

---

### Task A3: `URLProtocolStub` test helper

**Files:**
- Create: `EchoTests/Support/URLProtocolStub.swift`

This is the seam that makes every `AudiobookshelfService` test offline and deterministic. No production code; no test of its own (it is exercised by every later networking test).

- [ ] **Step 1: Implement the stub**

Create `EchoTests/Support/URLProtocolStub.swift`:

```swift
import Foundation

/// A `URLProtocol` that returns canned responses keyed by URL path suffix.
/// Register a session via `URLProtocolStub.makeSession()` and stub responses
/// with `URLProtocolStub.stub(pathSuffix:status:json:)`.
final class URLProtocolStub: URLProtocol {
    struct Response {
        var status: Int
        var body: Data
        var headers: [String: String]
    }

    // pathSuffix -> response. Last registration wins.
    nonisolated(unsafe) private static var responses: [String: Response] = [:]
    nonisolated(unsafe) private(set) static var requests: [URLRequest] = []

    static func reset() {
        responses = [:]
        requests = []
    }

    static func stub(pathSuffix: String, status: Int = 200, json: String, headers: [String: String] = [:]) {
        responses[pathSuffix] = Response(status: status, body: Data(json.utf8), headers: headers)
    }

    static func stub(pathSuffix: String, status: Int = 200, data: Data, headers: [String: String] = [:]) {
        responses[pathSuffix] = Response(status: status, body: data, headers: headers)
    }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [URLProtocolStub.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        let path = request.url?.path ?? ""
        let match = Self.responses.first { path.hasSuffix($0.key) }?.value
            ?? Response(status: 404, body: Data("{}".utf8), headers: [:])

        let response = HTTPURLResponse(
            url: request.url!, statusCode: match.status,
            httpVersion: "HTTP/1.1", headerFields: match.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: match.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
```

- [ ] **Step 2: Confirm it builds**

Run: `make build-tests`
Expected: build succeeds (no test asserts yet).

- [ ] **Step 3: Commit**

```bash
git add EchoTests/Support/URLProtocolStub.swift
git commit -m "test(abs): add URLProtocolStub for offline URLSession tests"
```

---

### Task A4: ABS API DTOs + error type + endpoint builder

**Files:**
- Create: `EchoCore/Services/Audiobookshelf/ABSModels.swift`
- Create: `EchoCore/Services/Audiobookshelf/ABSEndpoints.swift`
- Test: covered by A5/A6 (these are plain data types).

- [ ] **Step 1: Implement the endpoint builder**

Create `EchoCore/Services/Audiobookshelf/ABSEndpoints.swift`:

```swift
import Foundation

/// All Audiobookshelf URL construction in one place.
/// API verified against ABS v2.26+ (JWT auth + rotating refresh token).
/// NOTE: the media-progress path (`/api/me/progress/{id}`) should be confirmed
/// against the running server version during Milestone D bring-up; it is
/// isolated here so a correction is a one-line change.
struct ABSEndpoints {
    let baseURL: URL

    func login() -> URL { baseURL.appending(path: "login") }
    func refresh() -> URL { baseURL.appending(path: "auth/refresh") }
    func logout() -> URL { baseURL.appending(path: "logout") }
    func libraries() -> URL { baseURL.appending(path: "api/libraries") }

    func items(libraryID: String, page: Int, limit: Int, filter: String?) -> URL {
        var url = baseURL.appending(path: "api/libraries/\(libraryID)/items")
        var q = [URLQueryItem(name: "page", value: String(page)),
                 URLQueryItem(name: "limit", value: String(limit)),
                 URLQueryItem(name: "sort", value: "media.metadata.title")]
        if let filter { q.append(URLQueryItem(name: "filter", value: filter)) }
        url.append(queryItems: q)
        return url
    }

    func item(_ id: String) -> URL {
        baseURL.appending(path: "api/items/\(id)").appending(queryItems: [.init(name: "expanded", value: "1")])
    }

    /// Cover and file downloads authenticate via `?token=` (ABS-supported), so the
    /// URL is self-contained for `AsyncImage` / background downloads.
    func cover(_ id: String, token: String) -> URL {
        baseURL.appending(path: "api/items/\(id)/cover").appending(queryItems: [.init(name: "token", value: token)])
    }

    func fileDownload(itemID: String, ino: String, token: String) -> URL {
        baseURL.appending(path: "api/items/\(itemID)/file/\(ino)/download")
            .appending(queryItems: [.init(name: "token", value: token)])
    }

    func progress(_ itemID: String) -> URL { baseURL.appending(path: "api/me/progress/\(itemID)") }
    func localSessionsSync() -> URL { baseURL.appending(path: "api/session/local-all") }
}
```

- [ ] **Step 2: Implement the DTOs + error**

Create `EchoCore/Services/Audiobookshelf/ABSModels.swift`:

```swift
import Foundation

enum ABSError: Error, Equatable {
    case badURL
    case http(status: Int)
    case notAuthenticated          // no refresh token; need a fresh login
    case decoding(String)
    case noAudioFiles
}

// MARK: - Auth

/// `/login` (and `/auth/refresh`) return the token material under `user`.
/// We send `x-return-tokens: true` so the rotating refresh token is in the body.
struct ABSLoginResponse: Decodable {
    struct User: Decodable {
        let token: String?          // legacy permanent token (pre-2.26)
        let accessToken: String?    // new short-lived JWT
        let refreshToken: String?   // new rotating refresh token
    }
    let user: User
    let userDefaultLibraryId: String?

    var access: String? { user.accessToken ?? user.token }
    var refresh: String? { user.refreshToken }
}

// MARK: - Library browsing

struct ABSLibrariesResponse: Decodable { let libraries: [ABSLibrary] }
struct ABSLibrary: Decodable, Identifiable { let id: String; let name: String }

struct ABSItemsResponse: Decodable {
    let results: [ABSLibraryItem]
    let total: Int
    let page: Int
}

struct ABSLibraryItem: Decodable, Identifiable {
    let id: String
    let media: Media

    struct Media: Decodable {
        let metadata: Metadata
        let tags: [String]?
        let audioFiles: [AudioFile]?
        let ebookFile: EbookFile?
        let duration: Double?
    }
    struct Metadata: Decodable {
        let title: String?
        let authorName: String?
        let narratorName: String?
        let genres: [String]?
        let seriesName: String?
    }
    struct AudioFile: Decodable { let ino: String; let metadata: FileMeta }
    struct EbookFile: Decodable { let ino: String; let metadata: FileMeta }
    struct FileMeta: Decodable { let filename: String? }

    var title: String { media.metadata.title ?? "Untitled" }
    var author: String? { media.metadata.authorName }
    var duration: Double { media.duration ?? 0 }
    /// Genre + tag + series, deduped — the "topics" Echo persists on import.
    var topics: [String] {
        var t = Set<String>()
        media.metadata.genres?.forEach { t.insert($0) }
        media.tags?.forEach { t.insert($0) }
        if let s = media.metadata.seriesName { t.insert(s) }
        return t.sorted()
    }
}

// MARK: - Progress (Milestone D)

struct ABSMediaProgress: Codable {
    var currentTime: Double
    var duration: Double
    var progress: Double
    var isFinished: Bool
    var lastUpdate: Double?   // server epoch ms; authoritative timestamp
}
```

- [ ] **Step 3: Confirm it builds**

Run: `make build-tests`
Expected: build succeeds.

- [ ] **Step 4: Commit**

```bash
git add EchoCore/Services/Audiobookshelf/ABSModels.swift EchoCore/Services/Audiobookshelf/ABSEndpoints.swift
git commit -m "feat(abs): add ABS API DTOs, error type, and endpoint builder"
```

---

### Task A5: `AudiobookshelfService` — auth + serialized refresh-with-rotation

**Files:**
- Create: `EchoCore/Services/Audiobookshelf/AudiobookshelfService.swift`
- Test: `EchoTests/AudiobookshelfServiceAuthTests.swift`

This is the riskiest component. Two invariants from the spec: **(1)** persist the rotated refresh token *every time* a refresh succeeds; **(2)** serialize refreshes so two concurrent 401s don't both call `/auth/refresh` and invalidate each other ([ABS #5253](https://github.com/advplyr/audiobookshelf/issues/5253)).

- [ ] **Step 1: Write the failing auth tests**

Create `EchoTests/AudiobookshelfServiceAuthTests.swift`:

```swift
import Foundation
import Testing

@testable import Echo

@MainActor
@Suite struct AudiobookshelfServiceAuthTests {
    private func makeService() -> (AudiobookshelfService, ABSTokenStore) {
        URLProtocolStub.reset()
        let tokens = ABSTokenStore(serverID: "auth-\(UUID().uuidString)")
        let service = AudiobookshelfService(
            baseURL: URL(string: "http://homelab.local:13378")!,
            tokens: tokens,
            session: URLProtocolStub.makeSession())
        return (service, tokens)
    }

    @Test func loginStoresAccessAndRefreshTokens() async throws {
        let (service, tokens) = makeService()
        URLProtocolStub.stub(pathSuffix: "/login", json: """
        {"user":{"accessToken":"acc1","refreshToken":"ref1"},"userDefaultLibraryId":"lib1"}
        """)
        let defaultLib = try await service.login(username: "dan", password: "pw")
        #expect(tokens.accessToken == "acc1")
        #expect(tokens.refreshToken == "ref1")
        #expect(defaultLib == "lib1")
    }

    @Test func refreshRotatesAndPersistsTheRefreshToken() async throws {
        let (service, tokens) = makeService()
        tokens.refreshToken = "ref-old"
        URLProtocolStub.stub(pathSuffix: "/auth/refresh", json: """
        {"user":{"accessToken":"acc2","refreshToken":"ref-new"}}
        """)
        let newAccess = try await service.refreshAccessToken()
        #expect(newAccess == "acc2")
        #expect(tokens.accessToken == "acc2")
        #expect(tokens.refreshToken == "ref-new")   // rotation persisted
    }

    @Test func concurrentRefreshesCallTheEndpointOnce() async throws {
        let (service, tokens) = makeService()
        tokens.refreshToken = "ref-old"
        URLProtocolStub.stub(pathSuffix: "/auth/refresh", json: """
        {"user":{"accessToken":"acc3","refreshToken":"ref3"}}
        """)
        async let a = service.refreshAccessToken()
        async let b = service.refreshAccessToken()
        async let c = service.refreshAccessToken()
        _ = try await (a, b, c)
        let refreshCalls = URLProtocolStub.requests.filter { $0.url?.path.hasSuffix("/auth/refresh") == true }
        #expect(refreshCalls.count == 1)   // serialized: one network refresh, not three
    }

    @Test func refreshWithoutTokenThrowsNotAuthenticated() async {
        let (service, _) = makeService()
        await #expect(throws: ABSError.notAuthenticated) {
            _ = try await service.refreshAccessToken()
        }
    }
}
```

- [ ] **Step 2: Run to confirm failure**

Run: `make build-tests && make test-only FILTER=EchoTests/AudiobookshelfServiceAuthTests`
Expected: FAIL — `cannot find 'AudiobookshelfService' in scope`.

- [ ] **Step 3: Implement the service core + auth**

Create `EchoCore/Services/Audiobookshelf/AudiobookshelfService.swift`:

```swift
import Foundation

/// HTTP client for one Audiobookshelf server. Sibling to `CloudKitSyncService`:
/// a concrete `@MainActor final class`, constructor-injected, no protocol.
/// The `session` parameter is the test seam (inject a `URLProtocolStub` session).
@MainActor
final class AudiobookshelfService {
    private let endpoints: ABSEndpoints
    private let tokens: ABSTokenStore
    private let session: URLSession
    private let logger = Logger(category: "AudiobookshelfService")

    /// Serializes refreshes so concurrent 401s don't each rotate the token.
    private var inFlightRefresh: Task<String, Error>?

    init(baseURL: URL, tokens: ABSTokenStore, session: URLSession = .shared) {
        self.endpoints = ABSEndpoints(baseURL: baseURL)
        self.tokens = tokens
        self.session = session
    }

    // MARK: Auth

    /// POST /login. Sends `x-return-tokens: true` so the rotating refresh token
    /// is in the body (ABS otherwise sets it as an http-only cookie). Returns the
    /// server's default library id, if any.
    @discardableResult
    func login(username: String, password: String) async throws -> String? {
        var request = URLRequest(url: endpoints.login())
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("true", forHTTPHeaderField: "x-return-tokens")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["username": username, "password": password])

        let decoded: ABSLoginResponse = try await send(request, decode: ABSLoginResponse.self)
        guard let access = decoded.access else { throw ABSError.notAuthenticated }
        tokens.accessToken = access
        if let refresh = decoded.refresh { tokens.refreshToken = refresh }
        return decoded.userDefaultLibraryId
    }

    /// POST /auth/refresh with `x-refresh-token`. Serialized via `inFlightRefresh`.
    @discardableResult
    func refreshAccessToken() async throws -> String {
        if let existing = inFlightRefresh { return try await existing.value }
        guard let refresh = tokens.refreshToken else { throw ABSError.notAuthenticated }

        let task = Task<String, Error> { [endpoints, session, tokens] in
            var request = URLRequest(url: endpoints.refresh())
            request.httpMethod = "POST"
            request.setValue(refresh, forHTTPHeaderField: "x-refresh-token")
            let decoded: ABSLoginResponse = try await Self.sendStatic(request, session: session, decode: ABSLoginResponse.self)
            guard let access = decoded.access else { throw ABSError.notAuthenticated }
            tokens.accessToken = access
            if let rotated = decoded.refresh { tokens.refreshToken = rotated }  // persist EVERY time
            return access
        }
        inFlightRefresh = task
        defer { inFlightRefresh = nil }
        return try await task.value
    }

    func signOut() async {
        if let refresh = tokens.refreshToken {
            var request = URLRequest(url: endpoints.logout())
            request.httpMethod = "POST"
            request.setValue(refresh, forHTTPHeaderField: "x-refresh-token")
            _ = try? await session.data(for: request)
        }
        tokens.clear()
    }

    // MARK: Authorized request plumbing

    /// Performs `request` with a Bearer access token; on 401 refreshes once and retries.
    func authorized<T: Decodable>(_ request: URLRequest, decode type: T.Type) async throws -> T {
        var attempt = request
        if let access = tokens.accessToken {
            attempt.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
        }
        do {
            return try await send(attempt, decode: type)
        } catch ABSError.http(status: 401) {
            let access = try await refreshAccessToken()
            var retry = request
            retry.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
            return try await send(retry, decode: type)
        }
    }

    // MARK: Transport

    private func send<T: Decodable>(_ request: URLRequest, decode type: T.Type) async throws -> T {
        try await Self.sendStatic(request, session: session, decode: type)
    }

    /// Static so the refresh `Task` closure doesn't capture `self` (avoids actor reentrancy).
    nonisolated private static func sendStatic<T: Decodable>(
        _ request: URLRequest, session: URLSession, decode type: T.Type
    ) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ABSError.http(status: -1) }
        guard (200..<300).contains(http.statusCode) else { throw ABSError.http(status: http.statusCode) }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw ABSError.decoding(String(describing: error))
        }
    }
}
```

> The codebase already defines `Logger(category:)` (used throughout, e.g. `CloudKitSyncService.swift:17`). Reuse it.

- [ ] **Step 4: Run to confirm pass**

Run: `make test-only FILTER=EchoTests/AudiobookshelfServiceAuthTests`
Expected: PASS (all four tests, including the concurrency-serialization test).

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/Audiobookshelf/AudiobookshelfService.swift EchoTests/AudiobookshelfServiceAuthTests.swift
git commit -m "feat(abs): AudiobookshelfService auth — login + serialized refresh-with-rotation"
```

---

### Task A6: `AudiobookshelfService` — libraries, items, item detail

**Files:**
- Modify: `EchoCore/Services/Audiobookshelf/AudiobookshelfService.swift`
- Test: `EchoTests/AudiobookshelfServiceLibraryTests.swift`

- [ ] **Step 1: Write the failing test**

Create `EchoTests/AudiobookshelfServiceLibraryTests.swift`:

```swift
import Foundation
import Testing

@testable import Echo

@MainActor
@Suite struct AudiobookshelfServiceLibraryTests {
    private func makeService() -> AudiobookshelfService {
        URLProtocolStub.reset()
        let tokens = ABSTokenStore(serverID: "lib-\(UUID().uuidString)")
        tokens.accessToken = "acc"
        return AudiobookshelfService(
            baseURL: URL(string: "http://homelab.local:13378")!,
            tokens: tokens, session: URLProtocolStub.makeSession())
    }

    @Test func fetchLibrariesDecodes() async throws {
        let service = makeService()
        URLProtocolStub.stub(pathSuffix: "/api/libraries", json: """
        {"libraries":[{"id":"lib1","name":"Audiobooks"},{"id":"lib2","name":"Podcasts"}]}
        """)
        let libs = try await service.libraries()
        #expect(libs.map(\.id) == ["lib1", "lib2"])
    }

    @Test func fetchItemsDecodesTitleAuthorTopics() async throws {
        let service = makeService()
        URLProtocolStub.stub(pathSuffix: "/items", json: """
        {"total":1,"page":0,"results":[
          {"id":"it1","media":{"duration":3600,"tags":["studied"],
           "metadata":{"title":"Thinking Fast","authorName":"Kahneman","genres":["Psychology"],"seriesName":null}}}
        ]}
        """)
        let page = try await service.items(libraryID: "lib1", page: 0)
        #expect(page.results.first?.title == "Thinking Fast")
        #expect(page.results.first?.author == "Kahneman")
        #expect(page.results.first?.topics == ["Psychology", "studied"])
    }

    @Test func fetchItemDetailDecodesAudioAndEbook() async throws {
        let service = makeService()
        URLProtocolStub.stub(pathSuffix: "/api/items/it1", json: """
        {"id":"it1","media":{"duration":3600,
         "audioFiles":[{"ino":"100","metadata":{"filename":"book.m4b"}}],
         "ebookFile":{"ino":"200","metadata":{"filename":"book.epub"}},
         "metadata":{"title":"Thinking Fast","authorName":"Kahneman"}}}
        """)
        let item = try await service.item(id: "it1")
        #expect(item.media.audioFiles?.first?.ino == "100")
        #expect(item.media.ebookFile?.ino == "200")
    }
}
```

- [ ] **Step 2: Run to confirm failure**

Run: `make build-tests && make test-only FILTER=EchoTests/AudiobookshelfServiceLibraryTests`
Expected: FAIL — `value of type 'AudiobookshelfService' has no member 'libraries'`.

- [ ] **Step 3: Add the browse methods**

Append to `AudiobookshelfService` (before the closing brace, after `signOut`):

```swift
    // MARK: Browse

    func libraries() async throws -> [ABSLibrary] {
        let request = URLRequest(url: endpoints.libraries())
        return try await authorized(request, decode: ABSLibrariesResponse.self).libraries
    }

    func items(libraryID: String, page: Int = 0, limit: Int = 50, filter: String? = nil) async throws -> ABSItemsResponse {
        let request = URLRequest(url: endpoints.items(libraryID: libraryID, page: page, limit: limit, filter: filter))
        return try await authorized(request, decode: ABSItemsResponse.self)
    }

    func item(id: String) async throws -> ABSLibraryItem {
        let request = URLRequest(url: endpoints.item(id))
        return try await authorized(request, decode: ABSLibraryItem.self)
    }

    /// Self-contained cover URL for `AsyncImage` (token in query).
    func coverURL(itemID: String) -> URL? {
        guard let token = tokens.accessToken else { return nil }
        return endpoints.cover(itemID, token: token)
    }
```

- [ ] **Step 4: Run to confirm pass**

Run: `make test-only FILTER=EchoTests/AudiobookshelfServiceLibraryTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/Audiobookshelf/AudiobookshelfService.swift EchoTests/AudiobookshelfServiceLibraryTests.swift
git commit -m "feat(abs): AudiobookshelfService browse — libraries, items, item detail, cover URL"
```

---

### Task A7: "Connections" settings screen

**Files:**
- Create: `EchoCore/Views/Settings/ABSConnectionsSettingsView.swift`
- Modify: `EchoCore/Views/SettingsView.swift:143`
- Test: manual (SwiftUI view; verified in preview/app).

Follows the established async-UI house style (`ProTranscriptsSettingsView`: `@State` bools, `ProgressView` in the button, `.task`, an error `Section`).

- [ ] **Step 1: Add the Connections section to SettingsView**

In `EchoCore/Views/SettingsView.swift`, near the existing `NavigationLink("Smart Rewind") { SmartRewindSettingsView() }` (line ~143), add a new section:

```swift
            Section("Library Sources") {
                NavigationLink("Connections") {
                    ABSConnectionsSettingsView()
                }
            }
```

- [ ] **Step 2: Implement the view**

Create `EchoCore/Views/Settings/ABSConnectionsSettingsView.swift`:

```swift
import SwiftUI

struct ABSConnectionsSettingsView: View {
    @Environment(PlayerModel.self) private var model

    @State private var baseURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var connected: ABSServerRecord?
    @State private var isConnecting = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            if let server = connected {
                Section("Connected") {
                    LabeledContent("Server", value: server.baseURL)
                    LabeledContent("User", value: server.username)
                    Button("Sign Out", role: .destructive) {
                        Task { await signOut(server) }
                    }
                }
            } else {
                Section("Add Audiobookshelf Server") {
                    TextField("Server URL (http://host:13378)", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    TextField("Username", text: $username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                    Button {
                        Task { await connect() }
                    } label: {
                        if isConnecting { ProgressView() } else { Text("Connect") }
                    }
                    .disabled(isConnecting || baseURL.isEmpty || username.isEmpty)
                }
            }

            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) } header: { Text("Error") }
            }
        }
        .navigationTitle("Connections")
        .task { connected = try? model.absServerDAO.current() }
    }

    private func connect() async {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespaces)) else {
            errorMessage = "Invalid URL"; return
        }
        isConnecting = true; errorMessage = nil
        defer { isConnecting = false }
        do {
            let server = try await model.connectAudiobookshelf(baseURL: url, username: username, password: password)
            connected = server
            password = ""
        } catch {
            errorMessage = "Could not connect: \(error.localizedDescription)"
        }
    }

    private func signOut(_ server: ABSServerRecord) async {
        await model.disconnectAudiobookshelf(server)
        connected = nil
    }
}
```

- [ ] **Step 3: Add the PlayerModel glue**

`PlayerModel` already owns `databaseService` (set in `EchoCoreApp.swift`). Add a lazily-constructed DAO accessor and two intent methods. In `EchoCore/ViewModels/PlayerModel.swift` (a new `PlayerModel+Audiobookshelf.swift` extension file keeps `PlayerModel.swift` from growing — match the existing `PlayerModel+Bookmarks.swift` split):

Create `EchoCore/ViewModels/PlayerModel+Audiobookshelf.swift`:

```swift
import Foundation

extension PlayerModel {
    var absServerDAO: ABSServerDAO {
        ABSServerDAO(db: databaseService.writer)
    }

    /// Connect + persist the server (non-secret) and tokens (Keychain).
    @discardableResult
    func connectAudiobookshelf(baseURL: URL, username: String, password: String) async throws -> ABSServerRecord {
        let serverID = UUID().uuidString
        let tokens = ABSTokenStore(serverID: serverID)
        let service = AudiobookshelfService(baseURL: baseURL, tokens: tokens, session: .shared)
        let defaultLib = try await service.login(username: username, password: password)
        let record = ABSServerRecord(
            id: serverID, baseURL: baseURL.absoluteString, username: username,
            defaultLibraryId: defaultLib, addedAt: ISO8601DateFormatter().string(from: .now))
        try absServerDAO.save(record)
        absService = service           // cache the warm, logged-in instance (keeps access token + serialization)
        absServiceServerID = serverID
        return record
    }

    func disconnectAudiobookshelf(_ server: ABSServerRecord) async {
        let service = makeAudiobookshelfService()   // reuse cached instance if present
        await service?.signOut()
        try? absServerDAO.delete(server.id)
        absService = nil
        absServiceServerID = nil
    }

    /// The SINGLE, cached service for the connected server. One instance is required
    /// for correctness — NOT just efficiency:
    ///   • `ABSTokenStore.accessToken` is memory-only *per instance*: a fresh service
    ///     per call discards the login's access token and forces a refresh every time.
    ///   • `inFlightRefresh` serialization (Task A5) is *per instance*: fresh instances
    ///     per caller let concurrent refreshes collide — the exact `/auth/refresh`
    ///     self-invalidation (ABS #5253) A5 was built to prevent.
    /// Browse, import, and progress-push MUST all go through this one accessor.
    func makeAudiobookshelfService() -> AudiobookshelfService? {
        // Warm cache returns FIRST, before any DB read — this accessor is called
        // per-row in the Browse cover builder, so it must be a cheap dictionary
        // lookup, not a SQLite hit. `connect` seeds the cache; `disconnect` clears it,
        // so for single-server v1 the cache is authoritative. (Multi-server would
        // re-add a serverID check here.)
        if let cached = absService { return cached }
        guard let server = try? absServerDAO.current(), let url = URL(string: server.baseURL) else { return nil }
        let service = AudiobookshelfService(baseURL: url, tokens: ABSTokenStore(serverID: server.id), session: .shared)
        absService = service
        absServiceServerID = server.id
        return service
    }
}
```

> **Stored properties** (`absService`, `absServiceServerID`) cannot live in an extension — declare them in `PlayerModel.swift` near `showingABSBrowse`:
> ```swift
>     private var absService: AudiobookshelfService?
>     private var absServiceServerID: String?
> ```
> `databaseService` on `PlayerModel` is `DatabaseService` (set at launch). Confirm the property name/visibility in `PlayerModel.swift` and adjust if it is `private` (make `internal`).

- [ ] **Step 4: Build & manually verify**

Run: `make build-tests` (compiles the app target). Then run the app, Settings → Connections, enter a real ABS URL/credentials, confirm "Connected" appears and the server row persists across relaunch (re-open the screen).

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Views/Settings/ABSConnectionsSettingsView.swift EchoCore/Views/SettingsView.swift EchoCore/ViewModels/PlayerModel+Audiobookshelf.swift
git commit -m "feat(abs): Connections settings screen + PlayerModel connect/disconnect glue"
```

---

### Task A8: Browse UI (libraries → items → detail, read-only)

**Files:**
- Create: `EchoCore/Views/Audiobookshelf/ABSBrowseView.swift`
- Test: manual.

- [ ] **Step 1: Implement the browse view**

Create `EchoCore/Views/Audiobookshelf/ABSBrowseView.swift`:

```swift
import SwiftUI

struct ABSBrowseView: View {
    @Environment(PlayerModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var libraries: [ABSLibrary] = []
    @State private var selectedLibrary: ABSLibrary?
    @State private var items: [ABSLibraryItem] = []
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading…")
                } else if let errorMessage {
                    ContentUnavailableView("Couldn't load", systemImage: "wifi.slash", description: Text(errorMessage))
                } else {
                    List {
                        Picker("Library", selection: $selectedLibrary) {
                            ForEach(libraries) { lib in Text(lib.name).tag(Optional(lib)) }
                        }
                        ForEach(items) { item in
                            NavigationLink {
                                ABSItemDetailView(item: item)
                            } label: {
                                ABSItemRow(item: item, coverURL: model.makeAudiobookshelfService()?.coverURL(itemID: item.id))
                            }
                        }
                    }
                }
            }
            .navigationTitle("Audiobookshelf")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task { await loadLibraries() }
            // `.task(id:)` AUTO-CANCELS the prior item load when the selection changes —
            // prevents a slow older library's response from overwriting a newer one
            // (MVVM stale-async anti-pattern). Do NOT replace with `.onChange { Task {} }`.
            .task(id: selectedLibrary) { await loadItems() }
        }
    }

    private func loadLibraries() async {
        guard let service = model.makeAudiobookshelfService() else {
            errorMessage = "No server connected."; return
        }
        isLoading = true; defer { isLoading = false }
        do {
            libraries = try await service.libraries()
            selectedLibrary = libraries.first
        } catch { errorMessage = error.localizedDescription }
    }

    private func loadItems() async {
        guard let service = model.makeAudiobookshelfService(), let lib = selectedLibrary else { return }
        do {
            let result = try await service.items(libraryID: lib.id).results
            try Task.checkCancellation()   // bail if the selection already moved on
            items = result
        } catch is CancellationError {
            // superseded by a newer selection — ignore
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct ABSItemRow: View {
    let item: ABSLibraryItem
    let coverURL: URL?
    var body: some View {
        HStack {
            AsyncImage(url: coverURL) { $0.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.2) }
                .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading) {
                Text(item.title).lineLimit(1)
                if let author = item.author { Text(author).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
}

private struct ABSItemDetailView: View {
    let item: ABSLibraryItem
    var body: some View {
        Form {
            Section { Text(item.title).font(.headline); if let a = item.author { Text(a) } }
            if !item.topics.isEmpty {
                Section("Topics") { Text(item.topics.joined(separator: ", ")) }
            }
            // The "Add from Audiobookshelf" download action is added in Milestone B (Task B5).
        }
        .navigationTitle("Details")
    }
}
```

`ABSLibrary` must be `Hashable` for the `Picker` tag — add `Hashable` to its declaration in `ABSModels.swift`:

```swift
struct ABSLibrary: Decodable, Identifiable, Hashable { let id: String; let name: String }
```

- [ ] **Step 2: Build & manually verify**

Run the app on a device/sim with a reachable ABS server; from Connections, navigate to Browse, confirm libraries populate, items list with covers, detail shows topics.

- [ ] **Step 3: Commit**

```bash
git add EchoCore/Views/Audiobookshelf/ABSBrowseView.swift EchoCore/Services/Audiobookshelf/ABSModels.swift
git commit -m "feat(abs): read-only Browse UI (libraries -> items -> detail)"
```

**✅ Milestone A complete:** connect, persist, browse. Ship-able as "Audiobookshelf (browse-only)" if desired.

---

# Milestone B — Download-to-local: the core (Tier 9.2)

**Outcome (the MVP):** From an ABS item, "Add from Audiobookshelf" downloads the audio + any bundled EPUB into `Application Support/ABSLibrary/{remoteItemID}/`, then hands that folder to the **unchanged** `loadFolder`. The book plays, the EPUB is auto-imported, alignment/flashcards/search work, and CloudKit anchors are inherited if another device already computed them.

---

### Task B1: Provenance columns on `audiobook` + migration V22 + carry-over

> **Renumbered (2026-06-20):** this task's migration is **V22** throughout — every `V19` / `Schema_V19` / `SchemaV19Tests` / `v19_audiobook_abs_provenance` below means **V22** / `Schema_V22` / `SchemaV22Tests` / `v22_audiobook_abs_provenance`. See the Reconciliation banner.

**Files:**
- Create: `Shared/Database/Migrations/Schema_V19.swift`
- Modify: `Shared/Database/DAOs/AudiobookDAO.swift:48`
- Modify: `Shared/Database/DatabaseService.swift` (register V19)
- Modify: `EchoCore/Services/TimelineIngestionService.swift:22`
- Test: `EchoTests/SchemaV19Tests.swift`

**Critical design note:** `TimelineIngestionService` re-builds and `save()`s the `AudiobookRecord` on every load. GRDB `save` upserts *all* columns, so the new provenance fields would be **wiped on every re-open** unless ingestion carries them over. Step 4 fixes that; without it, B is silently broken on the second open.

- [ ] **Step 1: Write the failing migration test**

Create `EchoTests/SchemaV19Tests.swift`:

```swift
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct SchemaV19Tests {
    @Test func v19AddsProvenanceColumns() throws {
        let db = try DatabaseService(inMemory: ())
        let columns = Set(
            try db.read { db in
                try Row.fetchAll(db, sql: "PRAGMA table_info(audiobook)").map { $0["name"] as? String ?? "" }
            })
        #expect(columns.contains("source_type"))
        #expect(columns.contains("server_id"))
        #expect(columns.contains("remote_item_id"))
        #expect(columns.contains("topics_json"))
    }

    @Test func provenanceRoundTripsThroughAudiobookRecord() throws {
        let db = try DatabaseService(inMemory: ())
        let dao = AudiobookDAO(db: db.writer)
        let book = AudiobookRecord(
            id: "file:///abs/", title: "T", author: "A", duration: 1, fileCount: 1,
            addedAt: "2026-06-14T00:00:00Z",
            sourceType: "audiobookshelf", serverID: "srv1", remoteItemID: "it1", topicsJSON: "[\"Psychology\"]")
        try dao.save(book)
        let fetched = try dao.get("file:///abs/")
        #expect(fetched?.sourceType == "audiobookshelf")
        #expect(fetched?.remoteItemID == "it1")
    }
}
```

- [ ] **Step 2: Run to confirm failure**

Run: `make build-tests && make test-only FILTER=EchoTests/SchemaV19Tests`
Expected: FAIL — `no such column: source_type` and `AudiobookRecord` has no `sourceType` argument.

- [ ] **Step 3: Create migration + extend the record**

Create `Shared/Database/Migrations/Schema_V19.swift`:

```swift
import GRDB

/// V19 — Audiobookshelf provenance on the audiobook record. Nullable: a local
/// import leaves all four NULL and behaves exactly as before. `topics_json` is a
/// JSON array of genre/tag/series strings (library-level discovery; Milestone C).
enum Schema_V19 {
    nonisolated static func migrate(_ db: Database) throws {
        try db.alter(table: "audiobook") { t in
            t.add(column: "source_type", .text)       // "audiobookshelf" or NULL (local)
            t.add(column: "server_id", .text)
            t.add(column: "remote_item_id", .text)
            t.add(column: "topics_json", .text)
        }
    }
}
```

Register it in `DatabaseService.swift`, after the V18 line:

```swift
        migrator.registerMigration("v19_audiobook_abs_provenance") { db in try Schema_V19.migrate(db) }
```

Extend `AudiobookRecord` in `Shared/Database/DAOs/AudiobookDAO.swift` (nil defaults so existing construction sites compile unchanged):

```swift
struct AudiobookRecord: Codable, FetchableRecord, MutablePersistableRecord {
    var id: String
    var title: String
    var author: String?
    var duration: TimeInterval
    var fileCount: Int?
    var addedAt: String
    var sourceType: String?    = nil
    var serverID: String?      = nil
    var remoteItemID: String?  = nil
    var topicsJSON: String?    = nil

    static let databaseTableName = "audiobook"

    enum CodingKeys: String, CodingKey {
        case id, title, author, duration
        case fileCount = "file_count"
        case addedAt = "added_at"
        case sourceType = "source_type"
        case serverID = "server_id"
        case remoteItemID = "remote_item_id"
        case topicsJSON = "topics_json"
    }
}
```

- [ ] **Step 4: Carry provenance over on re-ingest**

In `EchoCore/Services/TimelineIngestionService.swift` around line 22 (where `AudiobookRecord(...)` is built and saved), fetch the existing row first and carry the four provenance fields:

```swift
        let existing = try? AudiobookDAO(db: db.writer).get(audiobookID)
        let audiobook = AudiobookRecord(
            id: audiobookID,
            title: title,
            author: author,
            duration: duration,
            fileCount: fileCount,
            addedAt: addedAt,
            sourceType: existing?.sourceType,
            serverID: existing?.serverID,
            remoteItemID: existing?.remoteItemID,
            topicsJSON: existing?.topicsJSON)
        try AudiobookDAO(db: db.writer).save(audiobook)
```

> Adapt the exact argument names to the existing constructor call at `TimelineIngestionService.swift:22-30` — keep whatever it already passes for `title/author/duration/fileCount/addedAt`, only *adding* the four `existing?.…` lines.

- [ ] **Step 5: Run to confirm pass**

Run: `make test-only FILTER=EchoTests/SchemaV19Tests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Shared/Database/Migrations/Schema_V19.swift Shared/Database/DAOs/AudiobookDAO.swift Shared/Database/DatabaseService.swift EchoCore/Services/TimelineIngestionService.swift EchoTests/SchemaV19Tests.swift
git commit -m "feat(abs): audiobook provenance columns (migration v19) + ingest carry-over"
```

---

### Task B2: `absLibraryDirectory` managed-folder helper

**Files:**
- Modify: `Shared/FileLocations.swift`
- Test: `EchoTests/ABSImportServiceTests.swift` (add a focused test here; the file is created fully in B4 — for now add just this case).

- [ ] **Step 1: Write the failing test**

Create `EchoTests/ABSImportServiceTests.swift` with one test:

```swift
import Foundation
import Testing

@testable import Echo

@Suite struct ABSImportServiceTests {
    @Test func absLibraryDirectoryIsUnderApplicationSupport() throws {
        let dir = try FileLocations.absLibraryDirectory(remoteItemID: "it1")
        #expect(dir.path.contains("ABSLibrary"))
        #expect(dir.lastPathComponent == "it1")
        #expect(FileManager.default.fileExists(atPath: dir.path))   // created on demand
        try? FileManager.default.removeItem(at: dir)
    }
}
```

- [ ] **Step 2: Run to confirm failure**

Run: `make build-tests && make test-only FILTER=EchoTests/ABSImportServiceTests`
Expected: FAIL — `type 'FileLocations' has no member 'absLibraryDirectory'`.

- [ ] **Step 3: Implement the helper**

In `Shared/FileLocations.swift`, after `epubUnpackedDirectory(safeID:)` (line ~42), add:

```swift
    /// App-owned home for an Audiobookshelf download. Persistent (Application
    /// Support, not Caches): these are user library files, not regenerable.
    /// Created on demand. Security-scoped accessors are no-ops here — it's ours.
    static func absLibraryDirectory(remoteItemID: String) throws -> URL {
        let dir = applicationSupportDirectory
            .appending(path: "ABSLibrary", directoryHint: .isDirectory)
            .appending(path: remoteItemID, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
```

- [ ] **Step 4: Run to confirm pass**

Run: `make test-only FILTER=EchoTests/ABSImportServiceTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Shared/FileLocations.swift EchoTests/ABSImportServiceTests.swift
git commit -m "feat(abs): absLibraryDirectory managed-folder helper"
```

---

### Task B3: Foreground file download in `AudiobookshelfService`

**Files:**
- Modify: `EchoCore/Services/Audiobookshelf/AudiobookshelfService.swift`
- Test: `EchoTests/AudiobookshelfServiceDownloadTests.swift`

Ship a **foreground** download first (de-risk per the spec); background comes in B6.

- [ ] **Step 1: Write the failing test**

Create `EchoTests/AudiobookshelfServiceDownloadTests.swift`:

```swift
import Foundation
import Testing

@testable import Echo

@MainActor
@Suite struct AudiobookshelfServiceDownloadTests {
    @Test func downloadFileWritesBytesToDestination() async throws {
        URLProtocolStub.reset()
        let tokens = ABSTokenStore(serverID: "dl-\(UUID().uuidString)")
        tokens.accessToken = "acc"
        let service = AudiobookshelfService(
            baseURL: URL(string: "http://homelab.local:13378")!,
            tokens: tokens, session: URLProtocolStub.makeSession())
        URLProtocolStub.stub(pathSuffix: "/file/100/download", data: Data("AUDIOBYTES".utf8))

        let dest = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).m4b")
        try await service.downloadFile(itemID: "it1", ino: "100", to: dest)

        #expect(FileManager.default.fileExists(atPath: dest.path))
        #expect(try Data(contentsOf: dest) == Data("AUDIOBYTES".utf8))
        try? FileManager.default.removeItem(at: dest)
    }
}
```

- [ ] **Step 2: Run to confirm failure**

Run: `make build-tests && make test-only FILTER=EchoTests/AudiobookshelfServiceDownloadTests`
Expected: FAIL — `no member 'downloadFile'`.

- [ ] **Step 3: Implement the download**

Append to `AudiobookshelfService`:

```swift
    // MARK: Download (foreground; background added in B6)

    /// Downloads one ABS file (audio or ebook) to `destination`. Token is in the
    /// query (ABS-supported), so no Authorization header is needed.
    func downloadFile(itemID: String, ino: String, to destination: URL) async throws {
        guard let token = tokens.accessToken else { throw ABSError.notAuthenticated }
        let url = endpoints.fileDownload(itemID: itemID, ino: ino, token: token)
        let (tempURL, response) = try await session.download(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ABSError.http(status: http.statusCode)
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
    }
```

- [ ] **Step 4: Run to confirm pass**

Run: `make test-only FILTER=EchoTests/AudiobookshelfServiceDownloadTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/Audiobookshelf/AudiobookshelfService.swift EchoTests/AudiobookshelfServiceDownloadTests.swift
git commit -m "feat(abs): foreground file download in AudiobookshelfService"
```

---

### Task B4: `ABSImportService` — orchestrate download → stamp → loadFolder

**Files:**
- Create: `EchoCore/Services/Audiobookshelf/ABSImportService.swift`
- Modify: `EchoTests/ABSImportServiceTests.swift` (add orchestration tests)
- Test: `EchoTests/ABSImportServiceTests.swift`

This is the heart of the synergy. The order matters:
1. Pre-insert an `AudiobookRecord` with provenance (we already know title/author/duration from the item) so the row exists *with* provenance before the pipeline runs (carry-over in B1 then preserves it).
2. Download every audio file + the ebook (if present) into the managed folder as flat siblings.
3. Hand the folder to `loadFolder` (unchanged) — the post-load scan auto-imports the sibling `.epub`.

- [ ] **Step 1: Write the failing orchestration test**

Add to `EchoTests/ABSImportServiceTests.swift`:

```swift
    @MainActor
    @Test func importStampsProvenanceAndFilesAudioPlusEpub() async throws {
        URLProtocolStub.reset()
        let tokens = ABSTokenStore(serverID: "imp-\(UUID().uuidString)")
        tokens.accessToken = "acc"
        let service = AudiobookshelfService(
            baseURL: URL(string: "http://homelab.local:13378")!,
            tokens: tokens, session: URLProtocolStub.makeSession())
        URLProtocolStub.stub(pathSuffix: "/file/100/download", data: Data("M4B".utf8))
        URLProtocolStub.stub(pathSuffix: "/file/200/download", data: Data("EPUB".utf8))

        let db = try DatabaseService(inMemory: ())
        let item = try JSONDecoder().decode(ABSLibraryItem.self, from: Data("""
        {"id":"it1","media":{"duration":3600,
         "audioFiles":[{"ino":"100","metadata":{"filename":"book.m4b"}}],
         "ebookFile":{"ino":"200","metadata":{"filename":"book.epub"}},
         "metadata":{"title":"Thinking Fast","authorName":"Kahneman","genres":["Psychology"]}}}
        """.utf8))

        let importer = ABSImportService(service: service, db: db, serverID: tokens.serverID)
        let folder = try await importer.prepareLocalFolder(for: item)   // download + stamp, no loadFolder

        // Files landed as flat siblings:
        let names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(names.contains("book.m4b"))
        #expect(names.contains("book.epub"))

        // Provenance stamped on the audiobook row, keyed by the folder URL:
        let id = folder.absoluteString
        let row = try AudiobookDAO(db: db.writer).get(id)
        #expect(row?.sourceType == "audiobookshelf")
        #expect(row?.remoteItemID == "it1")
        #expect(row?.topicsJSON?.contains("Psychology") == true)

        try? FileManager.default.removeItem(at: folder)
    }
```

> The test calls `prepareLocalFolder(for:)` — the download+stamp half — to keep the unit test free of `PlayerModel`/`loadFolder` (a UI-bound, fire-and-forget call). The full `import(item:into:)` that also calls `loadFolder` is verified manually in B5.

- [ ] **Step 2: Run to confirm failure**

Run: `make build-tests && make test-only FILTER=EchoTests/ABSImportServiceTests`
Expected: FAIL — `cannot find 'ABSImportService' in scope`.

- [ ] **Step 3: Implement the import service**

Create `EchoCore/Services/Audiobookshelf/ABSImportService.swift`:

```swift
import Foundation

/// Orchestrates "download an ABS item into the local pipeline".
/// Concrete, constructor-injected; the `service`/`db` are the seams.
@MainActor
struct ABSImportService {
    let service: AudiobookshelfService
    let db: DatabaseService
    let serverID: String
    private let logger = Logger(category: "ABSImportService")

    /// Downloads files into the managed folder and stamps provenance.
    /// Returns the folder URL to hand to `loadFolder`. Separated from the
    /// `loadFolder` call so it is unit-testable without `PlayerModel`.
    func prepareLocalFolder(
        for item: ABSLibraryItem,
        progress: ((Double) -> Void)? = nil
    ) async throws -> URL {
        let folder = try FileLocations.absLibraryDirectory(remoteItemID: item.id)

        // Collect (ino, filename) for audio + optional ebook.
        var files: [(ino: String, name: String)] = (item.media.audioFiles ?? []).compactMap {
            guard let name = $0.metadata.filename else { return nil }
            return ($0.ino, name)
        }
        guard !files.isEmpty else { throw ABSError.noAudioFiles }
        if let ebook = item.media.ebookFile, let name = ebook.metadata.filename {
            files.append((ebook.ino, name))   // sibling .epub → auto-imported by the pipeline
        }

        for (index, file) in files.enumerated() {
            let dest = folder.appending(path: file.name)
            try await service.downloadFile(itemID: item.id, ino: file.ino, to: dest)
            progress?(Double(index + 1) / Double(files.count))
        }

        // Stamp provenance BEFORE loadFolder; carry-over (B1) preserves it on re-ingest.
        let topicsJSON = (try? JSONEncoder().encode(item.topics)).map { String(decoding: $0, as: UTF8.self) }
        let record = AudiobookRecord(
            id: folder.absoluteString,
            title: item.title,
            author: item.author,
            duration: item.duration,
            fileCount: item.media.audioFiles?.count,
            addedAt: ISO8601DateFormatter().string(from: .now),
            sourceType: "audiobookshelf",
            serverID: serverID,
            remoteItemID: item.id,
            topicsJSON: topicsJSON)
        try AudiobookDAO(db: db.writer).save(record)

        return folder
    }
}
```

- [ ] **Step 4: Run to confirm pass**

Run: `make test-only FILTER=EchoTests/ABSImportServiceTests`
Expected: PASS (all three tests in the file).

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/Audiobookshelf/ABSImportService.swift EchoTests/ABSImportServiceTests.swift
git commit -m "feat(abs): ABSImportService — download files + stamp provenance into managed folder"
```

---

### Task B5: "Add from Audiobookshelf" action + import progress UI

**Files:**
- Modify: `EchoCore/Views/PlaylistView.swift:472`
- Modify: `EchoCore/Views/Audiobookshelf/ABSBrowseView.swift` (add the Add button to detail)
- Create: `EchoCore/Views/Audiobookshelf/ABSImportProgressView.swift`
- Modify: `EchoCore/ViewModels/PlayerModel+Audiobookshelf.swift` (add `importFromAudiobookshelf`)
- Test: manual (UI + real download).

- [ ] **Step 1: Add the entry-point button in PlaylistView**

In `EchoCore/Views/PlaylistView.swift`, beside the existing "Add Document" button (~line 472), add a button that presents the browse sheet. Add the state to `PlayerModel` (`var showingABSBrowse = false` near `showingDocumentImporter` at `PlayerModel.swift:77`), then:

```swift
                Button {
                    model.showingABSBrowse = true
                } label: {
                    Image(systemName: "server.rack")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(String(localized: "Add from Audiobookshelf"))
```

And present the sheet on the same view (near the existing `.fileImporter` at line 346):

```swift
        .sheet(isPresented: $model.showingABSBrowse) { ABSBrowseView() }
```

- [ ] **Step 2: Add the Add action to the item detail**

In `ABSBrowseView.swift`, replace the placeholder comment in `ABSItemDetailView` with an Add button that runs the import and shows progress:

```swift
private struct ABSItemDetailView: View {
    @Environment(PlayerModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let item: ABSLibraryItem
    @State private var importProgress: Double?
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section { Text(item.title).font(.headline); if let a = item.author { Text(a) } }
            if !item.topics.isEmpty { Section("Topics") { Text(item.topics.joined(separator: ", ")) } }

            Section {
                if let p = importProgress {
                    ABSImportProgressView(progress: p)
                } else {
                    Button("Add to Echo") { Task { await addToEcho() } }
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Details")
    }

    private func addToEcho() async {
        importProgress = 0
        do {
            try await model.importFromAudiobookshelf(item: item) { importProgress = $0 }
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            importProgress = nil
        }
    }
}
```

Create `EchoCore/Views/Audiobookshelf/ABSImportProgressView.swift`:

```swift
import SwiftUI

struct ABSImportProgressView: View {
    let progress: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: progress)
            Text("Downloading… \(Int(progress * 100))%").font(.caption).foregroundStyle(.secondary)
        }
    }
}
```

- [ ] **Step 3: Add the PlayerModel import intent**

Append to `EchoCore/ViewModels/PlayerModel+Audiobookshelf.swift`:

```swift
    /// Download an ABS item locally and load it through the existing pipeline.
    func importFromAudiobookshelf(item: ABSLibraryItem, progress: @escaping (Double) -> Void) async throws {
        guard let service = makeAudiobookshelfService(), let server = try? absServerDAO.current() else {
            throw ABSError.notAuthenticated
        }
        let importer = ABSImportService(service: service, db: databaseService, serverID: server.id)
        let folder = try await importer.prepareLocalFolder(for: item, progress: progress)
        loadFolder(folder, autoplay: false)   // unchanged pipeline: auto-imports sibling .epub
    }
```

> `loadFolder(_:autoplay:)` is `PlayerModel`'s existing method (`PlayerModel.swift:1021`). The sibling `.epub` is auto-discovered by `EPUBAutoImportScanner` during post-load — no extra call.

- [ ] **Step 4: Manual end-to-end verification**

On a device with a reachable ABS server hosting a book that has a bundled EPUB:
1. Library → Add from Audiobookshelf → pick the book → Add to Echo.
2. Confirm the progress bar advances and the player loads the book.
3. Open the Reader tab — confirm the EPUB imported (text shows).
4. Confirm chapters parsed (M4B) and playback works.
5. Re-open the book later and confirm provenance survived (query `audiobook` row, or add a temporary debug print) — proves the B1 carry-over.

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Views/PlaylistView.swift EchoCore/Views/Audiobookshelf/ABSBrowseView.swift EchoCore/Views/Audiobookshelf/ABSImportProgressView.swift EchoCore/ViewModels/PlayerModel+Audiobookshelf.swift EchoCore/ViewModels/PlayerModel.swift
git commit -m "feat(abs): Add-from-Audiobookshelf action + import progress UI"
```

---

### Task B6: Background, resumable downloads

**Files:**
- Modify: `EchoCore/Info.plist:47`
- Modify: `EchoCore/Services/Audiobookshelf/AudiobookshelfService.swift`
- Test: manual (background sessions are not unit-testable via `URLProtocol`).

Only attempt after B5's foreground happy-path is proven. A background `URLSession` requires a delegate and completion-handler plumbing in the `AppDelegate`/`App`; keep the foreground path as the fallback.

- [ ] **Step 1: Add the background fetch mode**

In `EchoCore/Info.plist`, the `UIBackgroundModes` array currently has `audio` and `fetch` (lines 47-49). Background `URLSession` needs no *new* mode key — `fetch` covers app refresh, and background transfers are governed by the session being a `background` configuration. **No plist change is strictly required**; confirm and only add a comment. (Leave the array as-is unless a download fails to resume in the background, in which case verify the entitlement, not the plist.)

- [ ] **Step 2: Add a background download manager (delegate-based)**

Add an `ABSDownloadManager` (NSObject + `URLSessionDownloadDelegate`) with a `background` configuration identifier `com.echo.abs.downloads`, store per-task destinations, move the finished file in `urlSession(_:downloadTask:didFinishDownloadingTo:)`, and surface progress via `urlSession(_:downloadTask:didWriteData:…)`. Wire the system completion handler in the App's `handleEventsForBackgroundURLSession`.

> This is genuinely net-new infrastructure (the app uses only `audio`/`fetch` modes today). Treat it as its own mini-spec at execution time; keep `prepareLocalFolder` calling the foreground `downloadFile` as the fallback when a background session is unavailable. Document the chosen approach inline.

- [ ] **Step 3: Manual verification**

Start a large download, background the app, confirm it completes and the book appears.

- [ ] **Step 4: Commit**

```bash
git add EchoCore/Services/Audiobookshelf/ AppDelegate-or-App-file Info.plist
git commit -m "feat(abs): background resumable downloads (foreground fallback retained)"
```

---

### Task B7: Verify the anchor-reuse win end-to-end

**Files:**
- Test: manual (two devices / two installs) + a focused note.

The payoff: `CloudKitSyncService.downloadAnchors` keys shared anchors on `title+author+duration` and **ignores** `audiobookID` (`CloudKitSyncService.swift:34-40,147-149`). A book downloaded on device 2 inherits device 1's WhisperKit anchors — skipping transcription.

- [ ] **Step 1: Verify**

1. On device 1, import a book from ABS and run auto-alignment (anchors upload to CloudKit).
2. On device 2 (same iCloud account), import the *same* ABS book.
3. Confirm device 2 seeds anchors from CloudKit without re-transcribing (watch the alignment progress log: it should report inherited anchors). This works because the downloaded copy has the same `title+author+duration` even though its `folderURL`-based `audiobookID` differs.

- [ ] **Step 2: Record the result**

Note the outcome in the PR description. No code expected unless inheritance fails (then investigate `EPUBAutoImportScanner.swift:168`'s `downloadAnchors` call, which already runs on import).

**✅ Milestone B complete:** the MVP. An ABS book downloads and is a first-class local book.

---

# Milestone C — Library discovery: search by topic (Tier 9.3)

**Outcome:** Browse/filter the connected ABS library by genre/tag/series/narrator/author (library-level discovery — distinct from `EPubBlockDAO.searchBlocks`, which is within-book). Topics persist onto import (already wired in B4's `topicsJSON`), so the local library is filterable too.

---

### Task C1: Topic filter in the items query

**Files:**
- Modify: `EchoCore/Services/Audiobookshelf/AudiobookshelfService.swift` (already accepts `filter:`)
- Modify: `EchoCore/Services/Audiobookshelf/ABSEndpoints.swift` (already builds `filter`)
- Test: `EchoTests/AudiobookshelfServiceLibraryTests.swift` (add a case)

ABS encodes library filters as `filter=<group>.<base64(value)>` (e.g. `genres.<base64>`). Add a typed builder so callers pass `(group, value)` rather than hand-encoding.

- [ ] **Step 1: Write the failing test**

Add to `EchoTests/AudiobookshelfServiceLibraryTests.swift`:

```swift
    @Test func topicFilterEncodesAsBase64Group() {
        let f = ABSItemFilter.genre("Psychology")
        // ABS expects "<group>.<base64(value)>"
        #expect(f.queryValue == "genres.\(Data("Psychology".utf8).base64EncodedString())")
    }
```

- [ ] **Step 2: Run to confirm failure**

Run: `make build-tests && make test-only FILTER=EchoTests/AudiobookshelfServiceLibraryTests`
Expected: FAIL — `cannot find 'ABSItemFilter'`.

- [ ] **Step 3: Implement the filter type**

In `ABSModels.swift`:

```swift
/// ABS library item filter. Encoded as "<group>.<base64(value)>".
enum ABSItemFilter {
    case genre(String), tag(String), series(String), narrator(String), author(String)

    var queryValue: String {
        let (group, value): (String, String)
        switch self {
        case .genre(let v):    (group, value) = ("genres", v)
        case .tag(let v):      (group, value) = ("tags", v)
        case .series(let v):   (group, value) = ("series", v)
        case .narrator(let v): (group, value) = ("narrators", v)
        case .author(let v):   (group, value) = ("authors", v)
        }
        return "\(group).\(Data(value.utf8).base64EncodedString())"
    }
}
```

Add an overload to `AudiobookshelfService.items` that takes `ABSItemFilter`:

```swift
    func items(libraryID: String, page: Int = 0, limit: Int = 50, topic: ABSItemFilter) async throws -> ABSItemsResponse {
        try await items(libraryID: libraryID, page: page, limit: limit, filter: topic.queryValue)
    }
```

- [ ] **Step 4: Run to confirm pass**

Run: `make test-only FILTER=EchoTests/AudiobookshelfServiceLibraryTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/Audiobookshelf/ABSModels.swift EchoCore/Services/Audiobookshelf/AudiobookshelfService.swift EchoTests/AudiobookshelfServiceLibraryTests.swift
git commit -m "feat(abs): typed ABS library topic filter (genre/tag/series/narrator/author)"
```

---

### Task C2: Topic search/filter UI in Browse

**Files:**
- Modify: `EchoCore/Views/Audiobookshelf/ABSBrowseView.swift`
- Test: manual.

- [ ] **Step 1: Add a searchable text filter + a topic scope**

Add `.searchable` to the items list and a `Menu`/`Picker` for filter group. On submit, call `service.items(libraryID:topic:)` (or a free-text title filter via the plain `filter:`/local contains). Keep it minimal: a search field that filters the loaded items locally by title/author/topics, plus a "Filter by topic" menu that re-queries with `ABSItemFilter`.

```swift
            .searchable(text: $searchText, prompt: "Title, author, or topic")
```

with a computed `filteredItems` that does a case-insensitive `contains` across `title`, `author`, and `topics`. (Local filtering is fine for a single page; server-side `ABSItemFilter` re-query is the menu action for large libraries.)

- [ ] **Step 2: Manual verification**

Confirm typing narrows the list; selecting a genre from the menu re-queries the server and shows only that genre.

- [ ] **Step 3: Commit**

```bash
git add EchoCore/Views/Audiobookshelf/ABSBrowseView.swift
git commit -m "feat(abs): topic search/filter in Browse (library-level discovery)"
```

> **Topics-on-import already done:** B4 persists `topicsJSON`. A follow-up (optional, note in PR) is to surface a local "filter by topic" in `PlaylistView` using `AudiobookRecord.topicsJSON` — that complements Echo's existing embedded topic tags and is a small, separable add.

**✅ Milestone C complete.**

---

# Milestone D — Two-way progress sync (Tier 9.4, fast-follow)

**Outcome:** For ABS-backed books, playback position pushes to ABS (throttled 15–30 s) and pulls on open, with ABS authoritative. CloudKit syncs only anchors, **not** progress, so the only conflict axis is Echo-local vs ABS.

---

### Task D1: `updatedAt` (ms) on the playback sidecar

**Files:**
- Modify: `EchoCore/Models/EchoPlaylistManifest.swift:21`
- Test: `EchoTests/` (add a manifest round-trip test, Swift Testing)

- [ ] **Step 1: Write the failing test**

Create `EchoTests/ManifestPlaybackStateTests.swift`:

```swift
import Foundation
import Testing

@testable import Echo

@Suite struct ManifestPlaybackStateTests {
    @Test func updatedAtDefaultsAndDecodesWhenMissing() throws {
        // Legacy JSON without updatedAt decodes with default 0 (resilient decoder).
        let legacy = Data(#"{"lastTrackId":"t1","lastPosition":12.5}"#.utf8)
        let state = try JSONDecoder().decode(EchoPlaylistManifest.ManifestPlaybackState.self, from: legacy)
        #expect(state.updatedAt == 0)
        #expect(state.lastPosition == 12.5)
    }
}
```

- [ ] **Step 2: Run to confirm failure**

Run: `make build-tests && make test-only FILTER=EchoTests/ManifestPlaybackStateTests`
Expected: FAIL — `value of type '…ManifestPlaybackState' has no member 'updatedAt'`.

- [ ] **Step 3: Add the field + decoder line**

In `EchoCore/Models/EchoPlaylistManifest.swift`, add to `ManifestPlaybackState` (line ~21) and its custom `init(from:)` (line ~61):

```swift
    var updatedAt: Int = 0   // epoch ms of the last local progress write; 0 = unknown
```
```swift
        updatedAt = try c.decodeIfPresent(Int.self, forKey: .updatedAt) ?? 0
```

(Add `case updatedAt` to its `CodingKeys` if it has an explicit one.)

- [ ] **Step 4: Run to confirm pass**

Run: `make test-only FILTER=EchoTests/ManifestPlaybackStateTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Models/EchoPlaylistManifest.swift EchoTests/ManifestPlaybackStateTests.swift
git commit -m "feat(abs): add updatedAt(ms) to ManifestPlaybackState for conflict resolution"
```

---

### Task D2: Get/patch media progress in `AudiobookshelfService`

**Files:**
- Modify: `EchoCore/Services/Audiobookshelf/AudiobookshelfService.swift`
- Test: `EchoTests/AudiobookshelfServiceProgressTests.swift`

- [ ] **Step 1: Write the failing test**

Create `EchoTests/AudiobookshelfServiceProgressTests.swift`:

```swift
import Foundation
import Testing

@testable import Echo

@MainActor
@Suite struct AudiobookshelfServiceProgressTests {
    private func makeService() -> AudiobookshelfService {
        URLProtocolStub.reset()
        let tokens = ABSTokenStore(serverID: "prog-\(UUID().uuidString)")
        tokens.accessToken = "acc"
        return AudiobookshelfService(
            baseURL: URL(string: "http://homelab.local:13378")!,
            tokens: tokens, session: URLProtocolStub.makeSession())
    }

    @Test func getProgressDecodes() async throws {
        let service = makeService()
        URLProtocolStub.stub(pathSuffix: "/api/me/progress/it1", json: """
        {"currentTime":120.0,"duration":3600.0,"progress":0.033,"isFinished":false,"lastUpdate":1718000000000}
        """)
        let p = try await service.progress(itemID: "it1")
        #expect(p?.currentTime == 120.0)
        #expect(p?.lastUpdate == 1718000000000)
    }

    @Test func patchProgressSendsBody() async throws {
        let service = makeService()
        URLProtocolStub.stub(pathSuffix: "/api/me/progress/it1", json: "{}")
        try await service.updateProgress(itemID: "it1",
            progress: ABSMediaProgress(currentTime: 200, duration: 3600, progress: 0.055, isFinished: false, lastUpdate: nil))
        let sent = URLProtocolStub.requests.first { $0.url?.path.hasSuffix("/api/me/progress/it1") == true }
        #expect(sent?.httpMethod == "PATCH")
    }
}
```

- [ ] **Step 2: Run to confirm failure**

Run: `make build-tests && make test-only FILTER=EchoTests/AudiobookshelfServiceProgressTests`
Expected: FAIL — `no member 'progress(itemID:)'`.

- [ ] **Step 3: Implement get/patch**

Append to `AudiobookshelfService`:

```swift
    // MARK: Progress (Milestone D)

    func progress(itemID: String) async throws -> ABSMediaProgress? {
        let request = URLRequest(url: endpoints.progress(itemID))
        do { return try await authorized(request, decode: ABSMediaProgress.self) }
        catch ABSError.http(status: 404) { return nil }   // no server-side progress yet
    }

    func updateProgress(itemID: String, progress: ABSMediaProgress) async throws {
        var request = URLRequest(url: endpoints.progress(itemID))
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(progress)
        _ = try await authorized(request, decode: EmptyDecodable.self)
    }
```

Add a tiny `EmptyDecodable` in `ABSModels.swift` for responses we ignore:

```swift
struct EmptyDecodable: Decodable {}
```

> **Verify the progress path** (`/api/me/progress/{id}`, PATCH) against the running ABS version during this task — it is the one endpoint the dated official docs left ambiguous. It is isolated in `ABSEndpoints`, so a correction is one line.

- [ ] **Step 4: Run to confirm pass**

Run: `make test-only FILTER=EchoTests/AudiobookshelfServiceProgressTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/Audiobookshelf/AudiobookshelfService.swift EchoCore/Services/Audiobookshelf/ABSModels.swift EchoTests/AudiobookshelfServiceProgressTests.swift
git commit -m "feat(abs): get/patch ABS media-progress"
```

---

### Task D3: Wire push (throttled) + pull (conflict policy)

**Files:**
- Modify: `EchoCore/ViewModels/PlayerModel+Audiobookshelf.swift`
- Modify: `EchoCore/ViewModels/PlayerModel.swift:843` (push hook) and `:711` (pull on load)
- Test: `EchoTests/` (a pure conflict-resolution unit test; the closures themselves are integration-verified manually)

Keep the wiring thin and ABS-gated: do nothing unless the current book's `AudiobookRecord.sourceType == "audiobookshelf"`.

- [ ] **Step 1: Write a failing conflict-policy unit test**

Create `EchoTests/ABSProgressConflictTests.swift`:

```swift
import Testing

@testable import Echo

@Suite struct ABSProgressConflictTests {
    @Test func absWinsWhenServerIsNewer() {
        let decision = ABSProgressConflict.resolve(localUpdatedAtMs: 1_000, localTime: 50,
                                                   serverLastUpdateMs: 2_000, serverTime: 75)
        #expect(decision == .useServer(time: 75))
    }
    @Test func localWinsWhenLocalIsNewer() {
        let decision = ABSProgressConflict.resolve(localUpdatedAtMs: 3_000, localTime: 90,
                                                   serverLastUpdateMs: 2_000, serverTime: 75)
        #expect(decision == .useLocal(time: 90))
    }
    @Test func serverWinsWhenLocalUnknown() {
        let decision = ABSProgressConflict.resolve(localUpdatedAtMs: 0, localTime: 0,
                                                   serverLastUpdateMs: 2_000, serverTime: 75)
        #expect(decision == .useServer(time: 75))
    }
}
```

- [ ] **Step 2: Run to confirm failure**

Run: `make build-tests && make test-only FILTER=EchoTests/ABSProgressConflictTests`
Expected: FAIL — `cannot find 'ABSProgressConflict'`.

- [ ] **Step 3: Implement the pure resolver**

Add to `ABSModels.swift` (pure, fully unit-tested — the policy lives apart from the side-effecting wiring):

```swift
/// Conflict policy for ABS-backed books. ABS is authoritative *unless* the local
/// sidecar has a strictly newer timestamp (offline edits). `lastUpdate==0` means
/// "local unknown" → trust the server.
enum ABSProgressConflict: Equatable {
    case useServer(time: Double)
    case useLocal(time: Double)

    static func resolve(localUpdatedAtMs: Int, localTime: Double,
                        serverLastUpdateMs: Int, serverTime: Double) -> ABSProgressConflict {
        if localUpdatedAtMs > serverLastUpdateMs { return .useLocal(time: localTime) }
        return .useServer(time: serverTime)
    }
}
```

- [ ] **Step 4: Wire the push (throttled) into `coordinator_saveProgress`**

In `PlayerModel.swift` add a throttle stamp near the other state (`private var lastABSPushAt: Date = .distantPast`). In the `coordinator_saveProgress` closure (line ~843), after the existing `persistence.saveBookProgress(...)`, append a gated push:

```swift
            self?.maybePushABSProgress(folder: folder, time: time)
```

Implement in the extension:

```swift
    private static let absPushInterval: TimeInterval = 20   // 15–30 s window

    func maybePushABSProgress(folder: String, time: TimeInterval) {
        guard Date().timeIntervalSince(lastABSPushAt) >= Self.absPushInterval else { return }
        guard let book = try? AudiobookDAO(db: databaseService.writer).get(folder),
              book.sourceType == "audiobookshelf", let remoteID = book.remoteItemID,
              let service = makeAudiobookshelfService() else { return }
        lastABSPushAt = .now
        Task {
            try? await service.updateProgress(itemID: remoteID, progress: ABSMediaProgress(
                currentTime: time, duration: book.duration,
                progress: book.duration > 0 ? time / book.duration : 0, isFinished: false, lastUpdate: nil))
        }
    }
```

> `lastABSPushAt` must be a stored property on `PlayerModel` (extensions can't add stored properties). Add `var lastABSPushAt: Date = .distantPast` in `PlayerModel.swift` near `showingABSBrowse`.

- [ ] **Step 5: Wire the pull on load (conflict policy)**

In `PlayerModel.swift` around the restore-on-load path (`:711`), after the local `getBookProgress` restore, add an ABS reconciliation that runs only for ABS-backed books: fetch `service.progress(itemID:)`, read the local sidecar `updatedAt`, run `ABSProgressConflict.resolve(...)`, and if `.useServer(time:)` wins, seek to that time (reuse the existing `audioEngine.seek(to:)` block). Gate the whole thing behind `book.sourceType == "audiobookshelf"`.

- [ ] **Step 6: Run the unit test + manual verify**

Run: `make test-only FILTER=EchoTests/ABSProgressConflictTests` → PASS.
Manual: play an ABS book ~30 s, confirm progress appears in the ABS web UI; advance position in ABS web UI, re-open in Echo, confirm it resumes at the ABS position.

- [ ] **Step 7: Commit**

```bash
git add EchoCore/ViewModels/PlayerModel.swift EchoCore/ViewModels/PlayerModel+Audiobookshelf.swift EchoCore/Services/Audiobookshelf/ABSModels.swift EchoTests/ABSProgressConflictTests.swift
git commit -m "feat(abs): two-way progress sync (throttled push, ABS-authoritative pull)"
```

---

### Task D4: Offline reconciliation (deferrable within the phase)

**Files:**
- Modify: `EchoCore/Services/Audiobookshelf/AudiobookshelfService.swift`
- Test: `EchoTests/AudiobookshelfServiceProgressTests.swift` (add a case)

Accumulate offline progress and replay on reconnect via `POST /api/session/local-all`. This is explicitly deferrable; if time-boxed, ship D1–D3 and leave a `// TODO(abs): offline local-all replay` with a tracking note. If implementing: add `syncLocalSessions(_:)` that POSTs the accumulated sessions array, and persist unsynced pushes (e.g. a small `abs_pending_progress` table or a JSON file) when `updateProgress` fails offline.

- [ ] **Step 1 (if implementing): test + method + replay-on-launch hook.** Otherwise, **Step 1: record the deferral** in the PR and ROADMAP §9.4.

**✅ Milestone D complete (D1–D3; D4 optional).**

---

## Out of Scope (ROADMAP §9.5 — post-1.0)

Do **not** implement here: Tier-1 streaming (`AVPlayer` fork), ABS bookmark/finished-state round-trip, multi-server. If a streamed-book CTA is wanted, that is a separate spec.

---

## Documentation Sync (required before PR)

Per CLAUDE.md, this workstream changes architecture, adds a feature, and changes the DB schema — docs must update. Use the `doc-sync` skill, and at minimum:

- [ ] **`ARCHITECTURE.md`** — new section "Audiobookshelf Integration": the download-to-local decision, `AudiobookshelfService` (auth/refresh), the managed-folder + sibling-EPUB synergy, provenance columns, progress-conflict policy.
- [ ] **`CHANGELOG.md`** — entries under each milestone's commits.
- [ ] **`ROADMAP.md`** — tick §9.1–9.4 checkboxes as milestones land; note the V18/V19 numbering and D4 deferral if applicable.
- [ ] **`README.md`** — WS8b row: flip from "Planned" wording as it ships.
- [ ] Run the **schema-migration-reviewer** agent (V18/V19 collision check) and **cross-platform-parity-reviewer** agent (Shared/ service is consumed by iOS UI only in v1 — confirm that's intentional, Mac is a fast-follow) before opening the PR.

---

## Self-Review

**Spec coverage (ROADMAP §9.1–9.4):**
- 9.1 `AudiobookshelfService` (A5), auth+refresh rotation+serialization (A5), Keychain credential storage + `abs_server` table (A1/A2), Connections settings (A7), browse (A6/A8) ✅
- 9.2 "Add from Audiobookshelf" beside `.fileImporter` (B5), background/resumable downloads (B6, foreground-first B3), managed folder (B2), pull bundled EPUB → auto-discover (B4), hand to `loadFolder` unchanged (B5), identity option B + provenance (B1), anchor-reuse verify (B7) ✅
- 9.3 topic browse/search (C1/C2), carry topics onto import (B4 `topicsJSON`) ✅
- 9.4 push/pull into progress closures (D3), `updatedAt` + conflict policy ABS-authoritative (D1/D3), offline reconciliation (D4, deferrable) ✅
- 9.5 explicitly excluded ✅

**Placeholder scan:** No "TBD/handle errors/etc." in code steps. The two genuinely-uncertain externals — the ABS media-progress path and the background-download delegate plumbing — are called out explicitly with concrete starting values and isolation, not left blank.

**Type consistency:** `AudiobookshelfService(baseURL:tokens:session:)`, `ABSTokenStore(serverID:)`, `ABSImportService(service:db:serverID:)`, `prepareLocalFolder(for:progress:)`, `ABSLibraryItem.topics`, `AudiobookRecord.topicsJSON`, `ABSProgressConflict.resolve(...)`, `ABSItemFilter.queryValue`, `FileLocations.absLibraryDirectory(remoteItemID:)` — names are used identically across the tasks that define and consume them.
