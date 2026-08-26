### Task 16: Add private CloudKit records and `CKSyncEngine`

## Controller integration contract

- Worktree: `/Users/dfakkeldy/.codex/worktrees/article-anthology-design/Echo`
- Frozen base: `132f38a21857643455a545f654d44c74b4b97fe3`
- Implement Task 16 only. Tasks 14–15 remain dependency-gated; do not begin Task 17 or Task 18.
- Do not modify `EchoCore/Services/Narration/NarrationService.swift`,
  `EchoCore/Services/Narration/NarrationFileNaming.swift`,
  `EchoTests/NarrationFileNamingTests.swift`, `Echo.xcodeproj/project.pbxproj`,
  `ARCHITECTURE.md`, any sibling worktree, or unrelated files.
- Echo's filesystem-synchronized Xcode root groups discover new Swift files
  without a project-file edit.
- Preserve the iOS 18, macOS 15, and watchOS 11 deployment floors, Swift 6
  strict concurrency, default Main Actor isolation, and the existing
  `iCloud.com.echo.audiobooks` entitlement.
- Keep this private Article Workshop sync completely separate from
  `CloudKitSyncService`, which is an existing public-database community-anchor
  service. Never put Article Workshop data in the public or shared database.
- The new path is offline-first. Local captures, revisions, and anthology
  projects remain usable and authoritative without CloudKit. Do not block local
  writes or UI work on network access.
- Construct the production `CKContainer`/`CKSyncEngine` lazily at an explicit
  start boundary. Do not create CloudKit objects during generic app or XCTest
  bootstrap; existing headless Echo lanes may lack CloudKit entitlements.
- Keep archive, asset-copy, canonical-JSON, and database work off the UI actor.
  Use genuinely `Sendable` value types or an actor-owned subsystem; do not use
  `@unchecked Sendable`, `nonisolated(unsafe)`, semaphores, or detached tasks as
  warning silencers.
- Use the failable async
  `CKSyncEngine.RecordZoneChangeBatch(pendingChanges:recordProvider:)`
  initializer so one request cannot exceed CloudKit's combined 250-record
  save/delete cap.
- The Article sync boundary must explicitly classify quota, network,
  server-record conflict, authentication, missing-zone, and partial-failure
  outcomes. Partial failures retry only failed records. Account changes preserve
  all local Article Workshop data.
- Treat every fetched record and asset as untrusted. Enforce the plan's bounded
  scalar/canonical-JSON/package limits before allocation or persistence, copy
  fetched `CKAsset` content out of CloudKit's temporary URL before returning
  from the event callback, and keep generated EPUB, narration, M4B, credentials,
  cookies, URLs in error logs, and raw error text out of CloudKit records.
- V39 is additive. Prove both fresh-install schema creation and V38-to-V39
  upgrade preservation. Delete outbox tombstones only after an acknowledged
  CloudKit deletion.
- Follow strict TDD: add behavior tests first, run each focused suite and record
  the expected RED reason, then implement the minimum production behavior,
  rerun GREEN, and refactor only while green. Expectations must be hand-derived
  and assert real behavior rather than mock existence.
- Local proof only: use the real production codec/DAO/conflict logic with a
  deterministic transport driver. Do not contact live CloudKit and do not claim
  physical-device or cross-device acceptance.
- Before commit, run the focused commands in this brief, any affected Article
  persistence suites, `git diff --check`, a privacy/protected-file scan, and
  confirm the worktree has only Task 16 changes.
- Commit coherent Task 16 work with the specified Conventional Commit message.
  Write the complete report to
  `.superpowers/sdd/2026-07-28-article-inbox-anthologies/task-16-report.md`.
  The report must include the exact base and head SHAs, RED and GREEN commands
  with counts/output summaries, migration/codec/conflict/engine evidence,
  privacy and protected-file checks, unresolved concerns, and separate pending
  gates for live CloudKit, physical/cross-device acceptance, hosted CI, merge,
  installation, and release. Return only status, commit SHA(s), a one-line test
  summary, and concerns.

**Files:**
- Create: `Shared/Database/Migrations/Schema_V39.swift`
- Modify: `Shared/Database/DatabaseService.swift`
- Create: `Shared/Database/DAOs/ArticleSyncDAO.swift`
- Create: `EchoCore/Services/ArticleWorkshop/ArticleCloudRecordCodec.swift`
- Create: `EchoCore/Services/ArticleWorkshop/ArticleSyncConflictResolver.swift`
- Create: `EchoCore/Services/ArticleWorkshop/ArticleWorkshopCloudSyncEngine.swift`
- Test: `EchoTests/ArticleWorkshop/SchemaV39ArticleSyncTests.swift`
- Test: `EchoTests/ArticleWorkshop/ArticleCloudRecordCodecTests.swift`
- Test: `EchoTests/ArticleWorkshop/ArticleSyncConflictResolverTests.swift`

**Interfaces:**
- Consumes: capture packages, revision records, anthology manifests.
- Produces: private-zone records and durable pending changes.

- [ ] **Step 1: Add schema, codec, and conflict tests**

Test:

- serialized `CKSyncEngine.State.Serialization` round-trip;
- outbox save/delete acknowledgment;
- deterministic record names;
- capture package encoded only as a `CKAsset`, not article text fields;
- fetched asset copied out of CloudKit temporary location before callback returns;
- malformed/oversized records rejected;
- sibling cleanup revisions both retained;
- concurrent anthology edits create a recovered copy;
- delete acknowledgment clears tombstone.

- [ ] **Step 2: Verify failure**

Run:

```bash
make test-only FILTER=EchoTests/SchemaV39ArticleSyncTests
make test-only FILTER=EchoTests/ArticleCloudRecordCodecTests
make test-only FILTER=EchoTests/ArticleSyncConflictResolverTests
```

Expected: missing sync types.

- [ ] **Step 3: Add V39 durable sync state**

```swift
try db.create(table: "article_sync_state") { t in
    t.column("id", .text).primaryKey().check(sql: "id = 'default'")
    t.column("engine_state", .blob)
    t.column("account_status", .text).notNull().defaults(to: "unknown")
    t.column("last_error_code", .text)
    t.column("updated_at", .text).notNull()
}

try db.create(table: "article_sync_outbox") { t in
    t.column("record_name", .text).primaryKey()
    t.column("record_type", .text).notNull()
    t.column("entity_id", .text).notNull()
    t.column("operation", .text).notNull()
    t.column("queued_at", .text).notNull()
}
```

Use outbox operation values `save` and `delete`. Retain delete rows until CloudKit acknowledges them.

- [ ] **Step 4: Implement record codec and zone ownership**

Use private database custom zone `EchoArticleWorkshop.v1` and record types:

```text
EchoArticleCapture   record name capture.<UUID>
EchoArticleRevision  record name revision.<UUID>
EchoAnthology        record name anthology.<UUID>
```

Capture package is a ZIPFoundation-created compressed `CKAsset`; metadata fields are bounded scalar values. Revision recipe/metadata and anthology project manifest are bounded canonical JSON. Cover is an optional `CKAsset`. Generated EPUB, narration, M4B, credentials, and logs never enter records.

- [ ] **Step 5: Implement the `CKSyncEngineDelegate` wrapper**

Configure:

```swift
let configuration = CKSyncEngine.Configuration(
    database: CKContainer(identifier: "iCloud.com.echo.audiobooks")
        .privateCloudDatabase,
    stateSerialization: storedState,
    delegate: self
)
```

Persist every `.stateUpdate`; apply fetched record changes transactionally; acknowledge sent saves/deletes; handle account changes without deleting local data; create the custom zone through pending database changes; provide batches from the durable outbox. Stage local CKAsset files under `articleSyncTemporaryDirectory` and clean them after acknowledgment/cancellation.

Use a real transport seam for tests:

```swift
protocol ArticleSyncEngineDriver: Sendable {
    func schedule(_ changes: [ArticlePendingCloudChange]) async
    func fetchChanges() async throws
    func sendChanges() async throws
}
```

The production `CKSyncEngine` driver and deterministic test driver justify this protocol.

- [ ] **Step 6: Run focused tests**

Run:

```bash
make build-tests
make test-only FILTER=EchoTests/SchemaV39ArticleSyncTests
make test-only FILTER=EchoTests/ArticleCloudRecordCodecTests
make test-only FILTER=EchoTests/ArticleSyncConflictResolverTests
```

Expected: pass without live CloudKit.

- [ ] **Step 7: Commit**

```bash
git add Shared/Database EchoCore/Services/ArticleWorkshop EchoTests/ArticleWorkshop
git commit -m "feat: sync article workshop through private CloudKit"
```

---
