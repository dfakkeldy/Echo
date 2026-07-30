### Task 3: Add atomic staging and durable file storage

**Files:**
- Modify: `Shared/FileLocations.swift`
- Create: `Shared/ArticleCapture/ArticleCaptureStagingWriter.swift`
- Create: `Shared/ArticleWorkshop/ArticleWorkshopFileStore.swift`
- Create: `EchoCore/Services/ArticleWorkshop/ArticleInboxIngestionService.swift`
- Test: `EchoTests/ArticleWorkshop/ArticleWorkshopFileStoreTests.swift`
- Test: `EchoTests/ArticleWorkshop/ArticleInboxIngestionServiceTests.swift`

**Interfaces:**
- Consumes: `ArticleCaptureEnvelope`, `ArticleCaptureDAO`.
- Produces: `ArticleCaptureStagingWriter.stage(_:)`, `ArticleWorkshopFileStore.importEnvelope(at:)`, `ArticleInboxIngestionService.drainStaging()`.

- [ ] **Step 1: Write failure, recovery, and idempotency tests**

```swift
@Test func completionMarkerIsWrittenAfterEnvelope() throws
@Test func incompletePackageIsIgnored() async throws
@Test func validPackageMovesIntoApplicationSupportAndDeletesStagingCopy() async throws
@Test func secondDrainOfSameCaptureUUIDDoesNotDuplicateRows() async throws
@Test func importedButUnclearedStagingPackageIsCleanedOnRetry() async throws
@Test func failedDestinationWriteLeavesCompleteStagingPackageForRetry() async throws
```

Use temporary roots injected into both writer and store. Assert the final layout is:

```text
staging/<capture UUID>/envelope.json
staging/<capture UUID>/complete
ArticleWorkshop/Captures/<capture UUID>/snapshot.json
```

- [ ] **Step 2: Verify failure**

Run:

```bash
make test-only FILTER=EchoTests/ArticleWorkshopFileStoreTests
make test-only FILTER=EchoTests/ArticleInboxIngestionServiceTests
```

Expected: missing file-location and storage APIs.

- [ ] **Step 3: Add file locations and the extension-safe writer**

Required APIs:

```swift
static func articleCaptureStagingDirectory() throws -> URL
static var articleWorkshopRootDirectory: URL
static func articleCaptureDirectory(id: UUID) -> URL
static func articleAnthologyDirectory(id: UUID) -> URL
static func articleEditionURL(anthologyID: UUID) -> URL
static var articleSyncTemporaryDirectory: URL

nonisolated struct ArticleCaptureStagingWriter {
    let root: URL
    func stage(_ envelope: ArticleCaptureEnvelope) throws -> URL
}
```

`stage(_:)` must encode first, reject data over `maxEnvelopeBytes`, write into `.<UUID>.partial`, atomically move to `<UUID>`, and write the empty `complete` marker last. On iOS, apply complete-until-first-authentication file protection to the staged directory.

- [ ] **Step 4: Implement idempotent host-app import**

`ArticleWorkshopFileStore.importEnvelope(at:)` verifies the marker, UUID/path agreement, schema version, byte bounds, and SHA-256 before writing `snapshot.json` atomically. `ArticleInboxIngestionService` inserts the DB record only after the durable Application Support package exists, and deletes staging only after both file and DB work succeed. If the DB already has the UUID and the durable package digest matches, it treats the operation as recovered success and removes staging.

- [ ] **Step 5: Run focused tests**

Run:

```bash
make build-tests
make test-only FILTER=EchoTests/ArticleWorkshopFileStoreTests
make test-only FILTER=EchoTests/ArticleInboxIngestionServiceTests
```

Expected: pass with no residue in the injected staging root.

- [ ] **Step 6: Commit**

```bash
git add Shared/FileLocations.swift Shared/ArticleCapture Shared/ArticleWorkshop EchoCore/Services/ArticleWorkshop EchoTests/ArticleWorkshop
git commit -m "feat: stage article captures atomically"
```

---

