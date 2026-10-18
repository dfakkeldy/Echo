# Article Inbox and Anthologies Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a private cross-device Article Inbox to Echo that captures reader-friendly webpage snapshots, supports optional structural cleanup, builds chaptered EPUB 3.3 anthologies, and reuses Echo's reader, narration, and M4B exporter.

**Architecture:** A multiplatform Safari share extension durably stages an inactive rendered-page envelope in Echo's App Group. The main app sanitizes it into immutable typed blocks, stores reversible cleanup revisions and ordered anthology projects in GRDB, and builds an atomic interoperable EPUB that is imported through Echo's normal book pipeline. Stable generated block and chapter identities preserve study data and narration across rebuilds; `CKSyncEngine` synchronizes source packages and projects through a private CloudKit zone while generated EPUB, narration, and M4B files remain local products.

**Tech Stack:** Swift 6, SwiftUI, Observation, GRDB, WebKit/Safari app extensions, ZIPFoundation, CryptoKit, CloudKit `CKSyncEngine`, Mozilla Readability 0.6.0, Swift Testing, EPUB 3.3, EPUBCheck 5.3.0.

## Global Constraints

- Preserve deployment floors: iOS 18, macOS 15, and watchOS 11.
- Preserve Swift 6 strict concurrency and default Main Actor isolation; file, archive, HTML, network, and CloudKit work must not block the UI actor.
- Keep the existing `feature/* -> nightly -> weekly -> main` release ladder.
- Execute in the dedicated linked worktree; treat the canonical checkout as read-only.
- Do not introduce a third-party runtime dependency beyond the explicitly approved vendored Mozilla Readability component; reuse ZIPFoundation already in Echo.
- Pin `@mozilla/readability` 0.6.0, npm integrity `sha512-juG5VWh4qAivzTAeMzvY9xs9HY5rAcr2E4I7tiSSCokRFi7XIZCAu92ZkSTsIj1OPceCifL3cpfteP3pDT9/QQ==`, git head `4d5dd0bbe0bfbc44e219dc86865131e79639e30b`, under Apache-2.0.
- Never persist cookies, authorization headers, form values, browser history, scripts, frames, or active remote embeds.
- Never silently refetch a captured webpage during cleanup, build, rebuild, narration, or export.
- Treat Readability output as untrusted input; canonical content must be Echo-owned typed blocks and every EPUB string must be XML-escaped.
- Use the private CloudKit database only for article workshop data; never route it through the existing public `CloudKitSyncService`.
- Keep generated EPUB and M4B outputs explicit and local; sync captures, revisions, project manifests, and source images only.
- Preserve stable article/block identity across rebuilds and reuse narration when only anthology order changes.
- Keep capture, EPUB validation, narration completion, M4B export, reader compatibility, device acceptance, and human listening as separate receipts.
- Add localized and accessible UI for iOS, iPadOS, and macOS.
- Use authored, licensed, or public-domain fixtures only; never commit real private captures.
- The plan is pinned to schema V36 on `origin/nightly` at `33c17fda`. At execution start, recheck the latest migration. When `nightly` has occupied V37, V38, or V39, renumber all three new migrations together before writing code.

---

## File and responsibility map

### Shared capture boundary

- Create `Shared/ArticleCapture/ArticleWorkshopLimits.swift` — centralized byte/count/redirect limits.
- Create `Shared/ArticleCapture/ArticleCaptureEnvelope.swift` — Codable rendered-page handoff contract.
- Create `Shared/ArticleCapture/ArticleCaptureStagingWriter.swift` — extension-safe atomic App Group writer.
- Modify `Shared/FileLocations.swift` — App Group staging, Application Support capture/project/edition, and sync-temp paths.

### Persistence and domain

- Create `Shared/Database/Migrations/Schema_V37.swift` — core capture, revision, anthology, entry, and build tables.
- Create `Shared/Database/Migrations/Schema_V38.swift` — generated EPUB stable chapter key on `epub_block`.
- Create `Shared/Database/Migrations/Schema_V39.swift` — private-sync state and durable outbox.
- Modify `Shared/Database/DatabaseService.swift` — register the three migrations in order.
- Create `Shared/Database/ArticleWorkshopRecords.swift` — GRDB records for captures, revisions, projects, entries, and builds.
- Create `Shared/Database/DAOs/ArticleCaptureDAO.swift` — capture/revision reads and writes.
- Create `Shared/Database/DAOs/AnthologyDAO.swift` — project, stable slot, entry order, and build receipt operations.
- Create `Shared/Database/DAOs/ArticleSyncDAO.swift` — serialized engine state and durable pending changes.
- Create `Shared/ArticleWorkshop/ArticleWorkshopModels.swift` — typed blocks, metadata, warnings, clean articles, manifests, and output status.
- Create `Shared/ArticleWorkshop/ArticleWorkshopFileStore.swift` — atomic import, package/asset storage, deletion, and size accounting.

### Extraction and capture

- Create `ThirdParty/Readability/Readability.js`, `LICENSE.md`, and `PIN.json` — exact approved upstream source and receipt.
- Create `Scripts/verify_readability_vendor.sh` — fail-closed pin/integrity/license verification.
- Create `Echo Share Extension/ArticleCapturePreprocessor.js` — upstream Readability plus Echo's Safari preprocessing adapter.
- Create `Echo Share Extension/Info.plist`, `EchoShareExtension.entitlements`, and `ShareViewController.swift` — multiplatform share extension.
- Modify `Echo.xcodeproj/project.pbxproj` — add/embed the extension in iOS and macOS hosts.
- Create `Shared/ArticleWorkshop/ArticleBlockSanitizer.swift` — inert XHTML to bounded typed blocks.
- Create `EchoCore/Services/ArticleWorkshop/ReadabilityWebExtractor.swift` — nonpersistent, resource-blocked WebKit DOM for URL-only fallback.
- Create `EchoCore/Services/ArticleWorkshop/ArticleURLCaptureService.swift` — bounded HTTP fetch and authentication-page classification.
- Create `EchoCore/Services/ArticleWorkshop/ArticleImageDownloader.swift` — verified local image assets with total-budget enforcement.
- Create `EchoCore/Services/ArticleWorkshop/ArticleInboxIngestionService.swift` — idempotent staging drain into GRDB/Application Support.

### Inbox and cleanup UI

- Create `Shared/ArticleWorkshop/LibraryMode.swift` — Books, Inbox, Anthologies.
- Create `EchoCore/Services/ArticleWorkshop/ArticleInboxService.swift` — inbox queries, duplicate warnings, deletion checks.
- Create `EchoCore/ViewModels/ArticleInboxViewModel.swift` — loading, selection, capture retry, and deletion presentation.
- Create `EchoCore/Views/ArticleWorkshop/LibraryModePicker.swift`.
- Create `EchoCore/Views/ArticleWorkshop/ArticleInboxView.swift`.
- Create `EchoCore/Views/ArticleWorkshop/ArticleDetailView.swift`.
- Modify `EchoCore/Views/Library/LibraryView.swift` and `Echo macOS/Views/MacLibraryView.swift` — mount the three Library modes.
- Create `Shared/ArticleWorkshop/ArticleRevisionService.swift` — deterministic reversible edit recipes.
- Create `EchoCore/ViewModels/ArticleCleanupViewModel.swift`.
- Create `EchoCore/Views/ArticleWorkshop/ArticleCleanupView.swift`.

### Anthology authoring and EPUB

- Create `EchoCore/Services/ArticleWorkshop/AnthologyService.swift` — project CRUD and immutable build-manifest assembly.
- Create `EchoCore/ViewModels/AnthologyListViewModel.swift` and `AnthologyBuilderViewModel.swift`.
- Create `EchoCore/Views/ArticleWorkshop/AnthologyListView.swift`, `AnthologyBuilderView.swift`, and `AnthologyDetailView.swift`.
- Create `Shared/ArticleWorkshop/AnthologyCoverRenderer.swift` — deterministic default PNG cover.
- Create `Shared/ArticleWorkshop/EPUBXMLWriter.swift` — package, navigation, XHTML, CSS, and provenance serializers.
- Create `Shared/ArticleWorkshop/AnthologyEPUBBuilder.swift` — ZIPFoundation package creation.
- Create `Shared/ArticleWorkshop/AnthologyEPUBPreflight.swift` — runtime structural validation.
- Create `EchoCore/Services/ArticleWorkshop/AnthologyBuildService.swift` — atomic build, receipt, and normal Echo import.

### Stable import, narration, and M4B

- Modify `Shared/EPUBXMLParsing.swift` and `Shared/EPUBBlockParser.swift` — carry trusted generated block ordinals.
- Modify `Shared/Database/EPubBlockRecord.swift` — optional `sourceChapterKey`.
- Modify `EchoCore/Services/EPUBImportService.swift` — generated-anthology reconcile policy.
- Create `EchoCore/Services/ArticleWorkshop/GeneratedAnthologyImportIdentity.swift`.
- Create `EchoCore/Services/ArticleWorkshop/GeneratedAnthologyImportReconciler.swift`.
- Modify `EchoCore/Services/Narration/NarrationChapterPlanner.swift`, `NarrationFileNaming.swift`, and `NarrationService.swift` — optional stable chapter key.
- Modify `EchoCore/ViewModels/PlayerModel+Narration.swift` — resolve anthology titles/voices and reuse stable files.
- Modify `EchoCore/Services/Export/NarrationCacheSource.swift` — prefer persisted narrated tracks ordered by `sort_order`.
- Create `EchoCore/Services/ArticleWorkshop/AnthologyNarrationStatusService.swift`.
- Create `EchoCore/Services/ArticleWorkshop/AnthologyM4BExportService.swift`.

### Private sync and lifecycle

- Create `EchoCore/Services/ArticleWorkshop/ArticleCloudRecordCodec.swift`.
- Create `EchoCore/Services/ArticleWorkshop/ArticleSyncConflictResolver.swift`.
- Create `EchoCore/Services/ArticleWorkshop/ArticleWorkshopCloudSyncEngine.swift`.
- Create `EchoCore/Services/ArticleWorkshop/ArticleWorkshopSyncCoordinator.swift`.
- Modify `EchoCore/Services/SettingsManager.swift`, `EchoCore/Views/SettingsView.swift`, and `Echo macOS/Views/MacSettingsView.swift`.
- Modify `EchoCore/EchoCore.entitlements`, `Echo macOS/Echo_macOS.entitlements`, and app lifecycle files only as required for the existing CloudKit container and background notification delivery.

### Verification and documentation

- Add focused suites under `EchoTests/ArticleWorkshop/`.
- Add public-safe fixtures under `EchoTests/Fixtures/ArticleWorkshop/`.
- Add `EchoTests/Fixtures/ArticleWorkshop/minimal-anthology.epub` generated by the production builder from a fixed manifest.
- Modify `.github/workflows/ci.yml` — validate the committed production fixture with pinned EPUBCheck 5.3.0.
- Modify `EchoCore/Localizable.xcstrings`, platform privacy manifests, `ARCHITECTURE.md`, `README.md`, `ROADMAP.md`, and `CHANGELOG.md`.

---

### Task 1: Pin Readability and define the capture envelope

**Files:**
- Create: `ThirdParty/Readability/Readability.js`
- Create: `ThirdParty/Readability/LICENSE.md`
- Create: `ThirdParty/Readability/PIN.json`
- Create: `Scripts/verify_readability_vendor.sh`
- Create: `Shared/ArticleCapture/ArticleWorkshopLimits.swift`
- Create: `Shared/ArticleCapture/ArticleCaptureEnvelope.swift`
- Test: `EchoTests/ArticleWorkshop/ArticleCaptureEnvelopeTests.swift`

**Interfaces:**
- Produces: `ArticleWorkshopLimits`, `ArticleCaptureEnvelope`, `ReadabilityCapturePayload`, `ArticleCaptureMethod`.
- Consumes: no prior task APIs.

- [ ] **Step 1: Add failing envelope and bounds tests**

```swift
@Suite struct ArticleCaptureEnvelopeTests {
    @Test func envelopeRoundTripsWithoutBrowserSecrets() throws {
        let payload = ReadabilityCapturePayload(
            sourceURL: "https://example.test/article",
            canonicalURL: "https://example.test/article",
            title: "A Small Article",
            byline: "A. Writer",
            siteName: "Example",
            language: "en",
            publishedTime: "2026-07-28",
            excerpt: "A fixture.",
            contentXHTML: "<article><p>Body.</p></article>",
            textContent: "Body.",
            imageURLs: []
        )
        let envelope = ArticleCaptureEnvelope(
            schemaVersion: 1,
            captureID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            capturedAt: Date(timeIntervalSince1970: 1_775_000_000),
            method: .safariRenderedPage,
            sourceApplication: "com.apple.mobilesafari",
            payload: payload
        )

        let data = try JSONEncoder.articleWorkshop.encode(envelope)
        let decoded = try JSONDecoder.articleWorkshop.decode(
            ArticleCaptureEnvelope.self, from: data)

        #expect(decoded == envelope)
        #expect(String(decoding: data, as: UTF8.self).contains("cookie") == false)
        #expect(String(decoding: data, as: UTF8.self).contains("authorization") == false)
    }

    @Test func limitsAreBounded() {
        #expect(ArticleWorkshopLimits.maxEnvelopeBytes == 12 * 1_024 * 1_024)
        #expect(ArticleWorkshopLimits.maxContentXHTMLBytes == 8 * 1_024 * 1_024)
        #expect(ArticleWorkshopLimits.maxDOMElements == 50_000)
        #expect(ArticleWorkshopLimits.maxBlocks == 20_000)
        #expect(ArticleWorkshopLimits.maxImages == 100)
        #expect(ArticleWorkshopLimits.maxSingleImageBytes == 12 * 1_024 * 1_024)
        #expect(ArticleWorkshopLimits.maxTotalImageBytes == 50 * 1_024 * 1_024)
        #expect(ArticleWorkshopLimits.maxRedirects == 5)
    }
}
```

- [ ] **Step 2: Run the tests and vendor check to verify failure**

Run:

```bash
make build-tests
make test-only FILTER=EchoTests/ArticleCaptureEnvelopeTests
bash Scripts/verify_readability_vendor.sh
```

Expected: the Swift suite fails to compile because the capture types do not exist; the shell check fails because the pinned files do not exist.

- [ ] **Step 3: Add the exact capture contract and limits**

```swift
nonisolated enum ArticleWorkshopLimits {
    static let maxEnvelopeBytes = 12 * 1_024 * 1_024
    static let maxContentXHTMLBytes = 8 * 1_024 * 1_024
    static let maxDOMElements = 50_000
    static let maxBlocks = 20_000
    static let maxImages = 100
    static let maxSingleImageBytes = 12 * 1_024 * 1_024
    static let maxTotalImageBytes = 50 * 1_024 * 1_024
    static let maxRedirects = 5
    static let maxURLResponseBytes = 12 * 1_024 * 1_024
}

nonisolated enum ArticleCaptureMethod: String, Codable, Sendable {
    case safariRenderedPage
    case urlFetch
}

nonisolated struct ReadabilityCapturePayload: Codable, Equatable, Sendable {
    let sourceURL: String
    let canonicalURL: String?
    let title: String?
    let byline: String?
    let siteName: String?
    let language: String?
    let publishedTime: String?
    let excerpt: String?
    let contentXHTML: String
    let textContent: String
    let imageURLs: [String]
}

nonisolated struct ArticleCaptureEnvelope: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let captureID: UUID
    let capturedAt: Date
    let method: ArticleCaptureMethod
    let sourceApplication: String?
    let payload: ReadabilityCapturePayload
}
```

Use fixed ISO-8601-with-fractional-seconds encoder/decoder factories so share extension and host app encode identically. Do not add credential-shaped fields.

- [ ] **Step 4: Vendor and verify Readability 0.6.0**

Commit the exact npm 0.6.0 `Readability.js` and Apache license. `PIN.json` must contain:

```json
{
  "package": "@mozilla/readability",
  "version": "0.6.0",
  "gitHead": "4d5dd0bbe0bfbc44e219dc86865131e79639e30b",
  "npmTarball": "https://registry.npmjs.org/@mozilla/readability/-/readability-0.6.0.tgz",
  "npmIntegrity": "sha512-juG5VWh4qAivzTAeMzvY9xs9HY5rAcr2E4I7tiSSCokRFi7XIZCAu92ZkSTsIj1OPceCifL3cpfteP3pDT9/QQ==",
  "npmSHA1": "134e3ce3ff1676716e550de0b8de957bcc59208b",
  "license": "Apache-2.0"
}
```

The verification script downloads the tarball to `mktemp -d`, checks npm integrity with `openssl dgst -sha512 -binary | openssl base64 -A`, extracts `package/Readability.js`, byte-compares it with the committed file, verifies `LICENSE.md`, and removes its temporary directory through a trap.

- [ ] **Step 5: Run focused verification**

Run:

```bash
make build-tests
make test-only FILTER=EchoTests/ArticleCaptureEnvelopeTests
bash Scripts/verify_readability_vendor.sh
git diff --check
```

Expected: both tests and the pin check pass.

- [ ] **Step 6: Commit**

```bash
git add ThirdParty/Readability Scripts/verify_readability_vendor.sh Shared/ArticleCapture EchoTests/ArticleWorkshop/ArticleCaptureEnvelopeTests.swift
git commit -m "feat: pin readability capture contract"
```

---

### Task 2: Add core Article Workshop persistence

**Files:**
- Create: `Shared/Database/Migrations/Schema_V37.swift`
- Modify: `Shared/Database/DatabaseService.swift`
- Create: `Shared/Database/ArticleWorkshopRecords.swift`
- Create: `Shared/Database/DAOs/ArticleCaptureDAO.swift`
- Create: `Shared/Database/DAOs/AnthologyDAO.swift`
- Test: `EchoTests/ArticleWorkshop/SchemaV37ArticleWorkshopTests.swift`
- Test: `EchoTests/ArticleWorkshop/ArticleWorkshopDAOTests.swift`

**Interfaces:**
- Consumes: `ArticleCaptureMethod`.
- Produces: `ArticleCaptureRecord`, `ArticleRevisionRecord`, `AnthologyRecord`, `AnthologyEntryRecord`, `AnthologyBuildRecord`, `ArticleCaptureDAO`, `AnthologyDAO`.

- [ ] **Step 1: Write migration and DAO lifecycle tests**

Cover:

```swift
@Test func v37CreatesWorkshopTablesAndRestrictsReferencedArticleDeletion() throws
@Test func captureAndCurrentRevisionRoundTrip() throws
@Test func anthologyAllocatesStableSlotsWithoutReusingRemovedSlots() throws
@Test func anthologyEntryOrderChangesWithoutChangingStableSlots() throws
@Test func failedBuildDoesNotReplaceLatestSuccessfulBuild() throws
```

The stable-slot test must create A/B with slots `0/1`, remove A, add C, and expect B/C slots `1/2` even when display order is C/B.

- [ ] **Step 2: Verify failure**

Run:

```bash
make test-only FILTER=EchoTests/SchemaV37ArticleWorkshopTests
make test-only FILTER=EchoTests/ArticleWorkshopDAOTests
```

Expected: compile failure for missing records, DAOs, and migration.

- [ ] **Step 3: Create the V37 schema**

Use these exact tables and constraints:

```swift
try db.create(table: "article_capture") { t in
    t.column("id", .text).primaryKey()
    t.column("source_url", .text).notNull()
    t.column("canonical_url", .text)
    t.column("title", .text).notNull()
    t.column("author", .text)
    t.column("site_name", .text)
    t.column("language", .text)
    t.column("published_at", .text)
    t.column("captured_at", .text).notNull()
    t.column("capture_method", .text).notNull()
    t.column("package_path", .text).notNull()
    t.column("content_sha256", .text).notNull()
    t.column("extractor_version", .text).notNull()
    t.column("content_state", .text).notNull()
    t.column("warnings_json", .text).notNull().defaults(to: "[]")
    t.column("current_revision_id", .text)
    t.column("created_at", .text).notNull()
    t.column("modified_at", .text).notNull()
}

try db.create(table: "article_revision") { t in
    t.column("id", .text).primaryKey()
    t.column("capture_id", .text).notNull()
        .references("article_capture", onDelete: .cascade)
    t.column("parent_revision_id", .text)
    t.column("metadata_overrides_json", .text).notNull()
    t.column("recipe_json", .text).notNull()
    t.column("readable_content_sha256", .text).notNull()
    t.column("created_at", .text).notNull()
    t.column("device_name", .text)
}

try db.create(table: "anthology") { t in
    t.column("id", .text).primaryKey()
    t.column("title", .text).notNull()
    t.column("subtitle", .text)
    t.column("creator", .text)
    t.column("cover_path", .text)
    t.column("next_stable_slot", .integer).notNull().defaults(to: 0)
    t.column("latest_build_revision", .integer).notNull().defaults(to: 0)
    t.column("created_at", .text).notNull()
    t.column("modified_at", .text).notNull()
}

try db.create(table: "anthology_entry") { t in
    t.column("id", .text).primaryKey()
    t.column("anthology_id", .text).notNull()
        .references("anthology", onDelete: .cascade)
    t.column("capture_id", .text).notNull()
        .references("article_capture", onDelete: .restrict)
    t.column("sort_order", .integer).notNull()
    t.column("stable_slot", .integer).notNull()
    t.column("chapter_title_override", .text)
    t.column("narration_voice_id", .text)
    t.uniqueKey(["anthology_id", "capture_id"])
    t.uniqueKey(["anthology_id", "stable_slot"])
}

try db.create(table: "anthology_build") { t in
    t.column("id", .text).primaryKey()
    t.column("anthology_id", .text).notNull()
        .references("anthology", onDelete: .cascade)
    t.column("revision", .integer).notNull()
    t.column("epub_identifier", .text).notNull()
    t.column("manifest_json", .text).notNull()
    t.column("manifest_sha256", .text).notNull()
    t.column("epub_path", .text)
    t.column("epub_sha256", .text)
    t.column("audiobook_id", .text)
    t.column("status", .text).notNull()
    t.column("error_code", .text)
    t.column("created_at", .text).notNull()
    t.uniqueKey(["anthology_id", "revision"])
}
```

Add indexes for capture date, normalized source URL, entry order, build revision, and revision parent. Register `v37_article_workshop` immediately after V36.

- [ ] **Step 4: Implement focused DAOs**

Required signatures:

```swift
struct ArticleCaptureDAO {
    init(db: DatabaseWriter)
    func saveCapture(_ record: ArticleCaptureRecord) throws
    func capture(id: String) throws -> ArticleCaptureRecord?
    func captures(includeFailures: Bool = true) throws -> [ArticleCaptureRecord]
    func possibleDuplicates(canonicalURL: String?, digest: String) throws -> [ArticleCaptureRecord]
    func saveRevision(_ revision: ArticleRevisionRecord, makeCurrent: Bool) throws
    func revisions(captureID: String) throws -> [ArticleRevisionRecord]
    func currentRevision(captureID: String) throws -> ArticleRevisionRecord?
    func deleteCapture(id: String) throws
}

struct AnthologyDAO {
    init(db: DatabaseWriter)
    func save(_ anthology: AnthologyRecord) throws
    func anthology(id: String) throws -> AnthologyRecord?
    func all() throws -> [AnthologyRecord]
    func addCapture(_ captureID: String, to anthologyID: String) throws -> AnthologyEntryRecord
    func replaceOrder(anthologyID: String, entryIDs: [String]) throws
    func entries(anthologyID: String) throws -> [AnthologyEntryRecord]
    func removeEntry(id: String) throws
    func saveBuild(_ build: AnthologyBuildRecord) throws
    func latestSuccessfulBuild(anthologyID: String) throws -> AnthologyBuildRecord?
    func referencingAnthologies(captureID: String) throws -> [AnthologyRecord]
}
```

Allocate `stable_slot` and increment `next_stable_slot` in one GRDB transaction.

- [ ] **Step 5: Run focused tests**

Run:

```bash
make build-tests
make test-only FILTER=EchoTests/SchemaV37ArticleWorkshopTests
make test-only FILTER=EchoTests/ArticleWorkshopDAOTests
git diff --check
```

Expected: pass.

- [ ] **Step 6: Commit**

```bash
git add Shared/Database EchoTests/ArticleWorkshop
git commit -m "feat: persist article workshop projects"
```

---

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

### Task 4: Sanitize extracted XHTML into immutable typed blocks

**Files:**
- Create: `Shared/ArticleWorkshop/ArticleWorkshopModels.swift`
- Create: `Shared/ArticleWorkshop/ArticleBlockSanitizer.swift`
- Create: `Shared/ArticleWorkshop/ArticleRevisionService.swift`
- Test: `EchoTests/ArticleWorkshop/ArticleBlockSanitizerTests.swift`
- Test: `EchoTests/ArticleWorkshop/ArticleRevisionServiceTests.swift`
- Create fixtures: `EchoTests/Fixtures/ArticleWorkshop/*.xhtml`

**Interfaces:**
- Consumes: `ReadabilityCapturePayload`, `ArticleWorkshopLimits`.
- Produces: `ArticleSnapshot`, `ArticleBlock`, `ArticleMetadata`, `ArticleEditRecipe`, `CleanArticle`.

- [ ] **Step 1: Add malicious and structural fixture tests**

Tests must prove:

```swift
@Test func keepsHeadingsParagraphsListsQuotesCodeImagesAndCaptions() throws
@Test func stripsScriptsFormsFramesEventHandlersAndHiddenActiveContent() throws
@Test func rejectsJavaScriptFileAndUnknownSchemes() throws
@Test func resolvesRelativeHTTPLinksAgainstSourceURL() throws
@Test func boundsBlockAndImageCandidateCounts() throws
@Test func malformedXHTMLBecomesReviewSuggestedWithoutExecutingAnything() throws
@Test func blockIDsRemainStableWhenCleanupExcludesNeighbors() throws
@Test func resetReturnsTheOriginalBlockSequence() throws
```

The malicious fixture includes `script`, `form`, `iframe`, `onclick`, `javascript:`, `file:`, oversized data URLs, and XML external-entity declarations.

- [ ] **Step 2: Verify failure**

Run:

```bash
make test-only FILTER=EchoTests/ArticleBlockSanitizerTests
make test-only FILTER=EchoTests/ArticleRevisionServiceTests
```

Expected: missing sanitizer and domain types.

- [ ] **Step 3: Add canonical domain values**

```swift
enum ArticleBlockKind: String, Codable, Sendable {
    case heading, paragraph, listItem, quote, code, image, separator
}

struct ArticleBlock: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let stableOrdinal: Int
    let kind: ArticleBlockKind
    let text: String?
    let sourceURL: URL?
    let imageCandidateURL: URL?
    let caption: String?
    let codeLanguage: String?
}

struct ArticleEditRecipe: Codable, Equatable, Sendable {
    var excludedBlockIDs: [String]
    var trimBeforeBlockID: String?
    var trimAfterBlockID: String?
    var metadataOverrides: ArticleMetadataOverrides
}
```

Create block IDs as `article-<capture UUID>-b<stable ordinal>` once during initial sanitation. Never renumber after cleanup.

- [ ] **Step 4: Implement a fail-closed `XMLParser` sanitizer**

`ArticleBlockSanitizer.sanitize(envelope:)` must:

- set `shouldResolveExternalEntities = false`;
- accept only the structural elements represented by `ArticleBlockKind`;
- keep text values, not arbitrary DOM;
- normalize only `http`/`https` URLs;
- convert `img` into image candidates rather than embedded active markup;
- stop at centralized bounds;
- derive `Ready`, `Review suggested`, or `Capture failed` from usable text and warnings;
- SHA-256 the canonical sorted-key JSON snapshot.

`ArticleRevisionService.apply(snapshot:recipe:)` validates all referenced block IDs, applies trim boundaries before exclusions, preserves base order, overlays metadata, and hashes only readable/spoken content.

- [ ] **Step 5: Run focused tests**

Run:

```bash
make build-tests
make test-only FILTER=EchoTests/ArticleBlockSanitizerTests
make test-only FILTER=EchoTests/ArticleRevisionServiceTests
```

Expected: pass; no fixture output contains executable markup.

- [ ] **Step 6: Commit**

```bash
git add Shared/ArticleWorkshop EchoTests/ArticleWorkshop EchoTests/Fixtures/ArticleWorkshop
git commit -m "feat: sanitize article snapshots into blocks"
```

---

### Task 5: Add the multiplatform Safari share extension

**Files:**
- Create: `Echo Share Extension/ArticleCapturePreprocessor.js`
- Create: `Echo Share Extension/Info.plist`
- Create: `Echo Share Extension/EchoShareExtension.entitlements`
- Create: `Echo Share Extension/ShareViewController.swift`
- Modify: `Echo.xcodeproj/project.pbxproj`
- Test: `EchoTests/ArticleWorkshop/ArticleShareCaptureHandlerTests.swift`

**Interfaces:**
- Consumes: `ArticleCaptureEnvelope`, `ArticleCaptureStagingWriter`, Readability 0.6.0.
- Produces: a complete App Group staging package and concise extension outcome.

- [ ] **Step 1: Add native-handler tests before target wiring**

Factor decoding/writing into:

```swift
nonisolated struct ArticleShareCaptureHandler {
    let stagingWriter: ArticleCaptureStagingWriter
    func handle(
        preprocessingResults: [String: Any],
        sourceApplication: String?,
        capturedAt: Date = Date()
    ) throws -> UUID
}
```

Tests cover valid rendered page, missing preprocessing result, over-limit XHTML, empty Readability result, and a writer failure that must not report success.

- [ ] **Step 2: Verify test failure**

Run:

```bash
make test-only FILTER=EchoTests/ArticleShareCaptureHandlerTests
```

Expected: missing handler.

- [ ] **Step 3: Build the Safari preprocessing adapter**

Start `ArticleCapturePreprocessor.js` with the exact vendored Readability 0.6.0 bytes, followed by an adapter that:

```javascript
var ExtensionPreprocessingJS = new function () {
  this.run = function (arguments) {
    var clone = document.cloneNode(true);
    var article = new Readability(clone, {
      maxElemsToParse: 50000,
      keepClasses: false
    }).parse();
    var payload = article ? {
      sourceURL: document.location.href,
      canonicalURL: document.querySelector("link[rel='canonical']")?.href || null,
      title: article.title || null,
      byline: article.byline || null,
      siteName: article.siteName || null,
      language: article.lang || document.documentElement.lang || null,
      publishedTime: article.publishedTime || null,
      excerpt: article.excerpt || null,
      contentXHTML: article.content || "",
      textContent: article.textContent || "",
      imageURLs: Array.from(
        new DOMParser().parseFromString(article.content || "", "text/html").images
      ).map(function (image) { return image.currentSrc || image.src; }).filter(Boolean)
    } : null;
    arguments.completionFunction({ echoArticleCapture: payload });
  };
};
```

Add a verification step to `verify_readability_vendor.sh` proving the combined file begins byte-for-byte with the pinned upstream file before the marked Echo adapter.

- [ ] **Step 4: Implement the extension controller**

Use `NSExtensionJavaScriptPreprocessingResultsKey` from a property-list attachment. The same target supports `iphoneos`, `iphonesimulator`, and `macosx`; `ShareViewController` conditionally subclasses `UIViewController` or `NSViewController`. It shows **Saving to Echo…**, calls the pure handler, then shows **Saved to Echo** only after `stage(_:)` succeeds and completes the extension request. Failure shows **Could not capture article** and cancels with the bounded error.

The extension:

- bundle ID `com.echo.audiobooks.share`;
- extension point `com.apple.share-services`;
- App Group `group.com.echo.audiobooks`;
- deployment iOS 18/macOS 15;
- activation for Safari webpage/property-list and URL inputs;
- no CloudKit entitlement and no credential access.

Embed the extension in both `Echo` and `Echo macOS` host products and include it in their schemes' build graph.

- [ ] **Step 5: Run handler tests and host builds**

Run:

```bash
make build-tests
make test-only FILTER=EchoTests/ArticleShareCaptureHandlerTests
xcodebuild build -project Echo.xcodeproj -scheme "Echo macOS" -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO -jobs 5
bash Scripts/verify_readability_vendor.sh
```

Expected: the extension compiles for both host schemes and tests pass. Simulator build success is not Safari acceptance.

- [ ] **Step 6: Commit**

```bash
git add "Echo Share Extension" Echo.xcodeproj/project.pbxproj Scripts/verify_readability_vendor.sh EchoTests/ArticleWorkshop
git commit -m "feat: capture Safari articles into Echo"
```

---

### Task 6: Add URL-only fallback and safe image localization

**Files:**
- Create: `EchoCore/Services/ArticleWorkshop/ReadabilityWebExtractor.swift`
- Create: `EchoCore/Services/ArticleWorkshop/ArticleURLCaptureService.swift`
- Create: `EchoCore/Services/ArticleWorkshop/ArticleImageDownloader.swift`
- Modify: `EchoCore/Services/ArticleWorkshop/ArticleInboxIngestionService.swift`
- Test: `EchoTests/ArticleWorkshop/ArticleURLCaptureServiceTests.swift`
- Test: `EchoTests/ArticleWorkshop/ArticleImageDownloaderTests.swift`

**Interfaces:**
- Consumes: `ReadabilityCapturePayload`, `ArticleSnapshot`, `ArticleWorkshopFileStore`.
- Produces: `ArticleURLCaptureService.capture(url:)`, localized image paths and warnings.

- [ ] **Step 1: Add bounded network tests with an injected `URLProtocol`**

Cover:

```swift
@Test func followsAtMostFiveHTTPRedirects() async throws
@Test func rejectsNonHTTPURLAndNonHTMLResponse() async throws
@Test func stopsReadingResponseAtTwelveMiB() async throws
@Test func classifiesLoginFormInsteadOfSavingItAsTheArticle() async throws
@Test func neverRefetchesDuringLaterSnapshotLoad() async throws
@Test func acceptsDecodedJPEGAndPNGOnlyWithinImageBudgets() async throws
@Test func imageFailureLeavesReadableTextAndAddsWarning() async throws
```

- [ ] **Step 2: Verify failure**

Run:

```bash
make test-only FILTER=EchoTests/ArticleURLCaptureServiceTests
make test-only FILTER=EchoTests/ArticleImageDownloaderTests
```

Expected: missing services.

- [ ] **Step 3: Implement bounded URL loading**

`ArticleURLCaptureService` accepts only `http` and `https`, uses an ephemeral injected `URLSession`, rejects non-HTML MIME types, enforces response/redirect limits in its delegate, and never stores request/response headers. A response dominated by password inputs, “sign in” headings, or a redirect to a known login path returns:

```swift
case authenticationRequired(
    message: "Open this page in Safari to capture the signed-in version."
)
```

- [ ] **Step 4: Extract with a network-silent WebKit document**

`ReadabilityWebExtractor` uses a nonpersistent `WKWebView`, disables page-authored JavaScript, installs a content rule that blocks all subresource loads, loads the already-fetched HTML with the source URL as base, and evaluates the pinned Readability source in the client content world. It returns the same `ReadabilityCapturePayload` used by Safari. Cancellation tears down the navigation and continuation exactly once.

`ArticleImageDownloader` separately downloads normalized `http`/`https` candidates, verifies MIME and decoded image dimensions with ImageIO, writes accepted assets atomically under the capture directory, and stops at `maxImages`, `maxSingleImageBytes`, or `maxTotalImageBytes`.

- [ ] **Step 5: Run focused tests**

Run:

```bash
make build-tests
make test-only FILTER=EchoTests/ArticleURLCaptureServiceTests
make test-only FILTER=EchoTests/ArticleImageDownloaderTests
```

Expected: pass without network access beyond the injected protocol.

- [ ] **Step 6: Commit**

```bash
git add EchoCore/Services/ArticleWorkshop EchoTests/ArticleWorkshop
git commit -m "feat: add local URL article capture"
```

---

### Task 7: Add the Article Inbox and Library mode selector

**Files:**
- Create: `Shared/ArticleWorkshop/LibraryMode.swift`
- Create: `EchoCore/Services/ArticleWorkshop/ArticleInboxService.swift`
- Create: `EchoCore/ViewModels/ArticleInboxViewModel.swift`
- Create: `EchoCore/Views/ArticleWorkshop/LibraryModePicker.swift`
- Create: `EchoCore/Views/ArticleWorkshop/ArticleInboxView.swift`
- Create: `EchoCore/Views/ArticleWorkshop/ArticleDetailView.swift`
- Modify: `EchoCore/Views/Library/LibraryView.swift`
- Test: `EchoTests/ArticleWorkshop/ArticleInboxServiceTests.swift`
- Test: `EchoTests/ArticleWorkshop/ArticleInboxViewModelTests.swift`

**Interfaces:**
- Consumes: capture DAO, file store, ingestion service.
- Produces: first coherent local workflow from staged Safari capture to selectable Inbox article.

- [ ] **Step 1: Add service and view-model tests**

```swift
@Test func inboxOrdersNewestFirstAndShowsReadyReviewAndFailedStates() throws
@Test func ingestionRunsBeforeInboxReload() async throws
@Test func duplicateIsWarningAndKeepBothRemainsAvailable() throws
@Test func multiSelectionCreatesAnAnthologySeedWithoutEditing() throws
@Test func referencedArticleDeletionReturnsAffectedProjectNames() throws
@Test func unreferencedDeletionRemovesDatabaseAndPackage() throws
```

- [ ] **Step 2: Verify failure**

Run:

```bash
make test-only FILTER=EchoTests/ArticleInboxServiceTests
make test-only FILTER=EchoTests/ArticleInboxViewModelTests
```

Expected: missing service/view model.

- [ ] **Step 3: Implement the Inbox service**

Required API:

```swift
@MainActor @Observable
final class ArticleInboxViewModel {
    var articles: [ArticleInboxItem] = []
    var selectedIDs: Set<String> = []
    var isImporting = false
    var errorMessage: String?

    init(db: DatabaseService, fileStore: ArticleWorkshopFileStore)
    func reload() async
    func toggleSelection(_ id: String)
    func selectAll()
    func deletionImpact(for id: String) throws -> ArticleDeletionImpact
    func delete(id: String) async
}
```

`reload()` drains complete staging packages first, then fetches. It never blocks on image downloads or iCloud.

- [ ] **Step 4: Mount Books, Inbox, and Anthologies in iOS Library**

`LibraryMode` is:

```swift
enum LibraryMode: String, CaseIterable, Identifiable, Sendable {
    case books, inbox, anthologies
    var id: Self { self }
}
```

Add a segmented picker under the Library title. Keep all existing shelf toolbar actions visible only in Books. Inbox provides multi-select, **New Anthology**, duplicate warning, **Clean Up**, and deletion confirmation. A Ready article can proceed directly to anthology selection.

- [ ] **Step 5: Run tests and iOS build**

Run:

```bash
make build-tests
make test-only FILTER=EchoTests/ArticleInboxServiceTests
make test-only FILTER=EchoTests/ArticleInboxViewModelTests
```

Expected: pass; the existing Library tests remain green.

- [ ] **Step 6: Commit**

```bash
git add Shared/ArticleWorkshop EchoCore/Services/ArticleWorkshop EchoCore/ViewModels/ArticleInboxViewModel.swift EchoCore/Views/ArticleWorkshop EchoCore/Views/Library/LibraryView.swift EchoTests/ArticleWorkshop
git commit -m "feat: add article inbox to Library"
```

---

### Task 8: Add macOS Library and capture parity

**Files:**
- Modify: `Echo macOS/Views/MacLibraryView.swift`
- Modify: `Echo Share Extension/ShareViewController.swift`
- Modify: `Echo.xcodeproj/project.pbxproj`
- Test: `EchoTests/ArticleWorkshop/LibraryModeTests.swift`

**Interfaces:**
- Consumes: shared Inbox services and views.
- Produces: Books/Inbox/Anthologies modes and Safari share capture on macOS.

- [ ] **Step 1: Add platform-neutral mode tests**

Test mode labels, symbols, selection persistence only within the Library session, and toolbar-policy mapping:

```swift
#expect(LibraryMode.books.availableActions.contains(.addFolder))
#expect(LibraryMode.inbox.availableActions.contains(.newAnthology))
#expect(LibraryMode.anthologies.availableActions.contains(.build))
#expect(LibraryMode.inbox.availableActions.contains(.addFolder) == false)
```

- [ ] **Step 2: Verify failure**

Run:

```bash
make test-only FILTER=EchoTests/LibraryModeTests
```

Expected: missing action policy.

- [ ] **Step 3: Implement Mac mode UI**

Place a native segmented picker in `MacLibraryView.header`. Preserve the existing sidebar list and Roots section in Books. Mount the shared Inbox and Anthology views in their modes, with keyboard-accessible selection and move commands. Use conditional view modifiers only where platform APIs differ.

- [ ] **Step 4: Verify the extension is embedded in the Mac host**

Build settings must embed the `Echo Share Extension.appex` in `Echo macOS.app/Contents/PlugIns`, use the same App Group, and compile the `NSViewController` branch. Do not claim Safari acceptance from this build.

- [ ] **Step 5: Run focused tests and Mac build**

Run:

```bash
make test-only FILTER=EchoTests/LibraryModeTests
xcodebuild build -project Echo.xcodeproj -scheme "Echo macOS" -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO -jobs 5
```

Expected: pass/build succeeds.

- [ ] **Step 6: Commit**

```bash
git add "Echo macOS/Views/MacLibraryView.swift" "Echo Share Extension" Echo.xcodeproj/project.pbxproj Shared/ArticleWorkshop EchoTests/ArticleWorkshop
git commit -m "feat: add Mac article workshop parity"
```

---

### Task 9: Add reversible on-demand structural cleanup

**Files:**
- Create: `EchoCore/ViewModels/ArticleCleanupViewModel.swift`
- Create: `EchoCore/Views/ArticleWorkshop/ArticleCleanupView.swift`
- Modify: `EchoCore/Views/ArticleWorkshop/ArticleDetailView.swift`
- Test: `EchoTests/ArticleWorkshop/ArticleCleanupViewModelTests.swift`

**Interfaces:**
- Consumes: `ArticleRevisionService`, capture/revision DAO.
- Produces: saved immutable revision recipes and reset/restore behavior.

- [ ] **Step 1: Add cleanup state tests**

Cover remove/restore, trim before/after, metadata correction, reset, no arbitrary text replacement API, save-as-child revision, and a concurrent sibling revision surfaced as conflict.

- [ ] **Step 2: Verify failure**

Run:

```bash
make test-only FILTER=EchoTests/ArticleCleanupViewModelTests
```

Expected: missing cleanup view model.

- [ ] **Step 3: Implement the view model**

```swift
@MainActor @Observable
final class ArticleCleanupViewModel {
    private(set) var source: ArticleSnapshot
    var recipe: ArticleEditRecipe
    var preview: CleanArticle
    var hasUnsavedChanges: Bool

    func exclude(blockID: String)
    func restore(blockID: String)
    func trimBefore(blockID: String)
    func trimAfter(blockID: String)
    func updateMetadata(_ overrides: ArticleMetadataOverrides)
    func reset()
    func save(deviceName: String?) throws -> ArticleRevisionRecord
}
```

Every mutation recomputes preview through `ArticleRevisionService`; UI never mutates base blocks.

- [ ] **Step 4: Build the structural editor**

Use block rows with Remove/Restore, contextual **Trim everything above/below**, and a metadata sheet. Do not add a general `TextEditor` for article prose. Excluded rows remain visible in a collapsed/restorable state. Provide VoiceOver actions equivalent to swipe/context actions.

- [ ] **Step 5: Run focused tests**

Run:

```bash
make build-tests
make test-only FILTER=EchoTests/ArticleCleanupViewModelTests
```

Expected: pass.

- [ ] **Step 6: Commit**

```bash
git add EchoCore/ViewModels/ArticleCleanupViewModel.swift EchoCore/Views/ArticleWorkshop EchoTests/ArticleWorkshop
git commit -m "feat: add reversible article cleanup"
```

---

### Task 10: Add anthology projects, stable entry slots, and builder UI

**Files:**
- Create: `EchoCore/Services/ArticleWorkshop/AnthologyService.swift`
- Create: `EchoCore/ViewModels/AnthologyListViewModel.swift`
- Create: `EchoCore/ViewModels/AnthologyBuilderViewModel.swift`
- Create: `EchoCore/Views/ArticleWorkshop/AnthologyListView.swift`
- Create: `EchoCore/Views/ArticleWorkshop/AnthologyBuilderView.swift`
- Create: `EchoCore/Views/ArticleWorkshop/AnthologyDetailView.swift`
- Test: `EchoTests/ArticleWorkshop/AnthologyServiceTests.swift`
- Test: `EchoTests/ArticleWorkshop/AnthologyBuilderViewModelTests.swift`

**Interfaces:**
- Consumes: capture/revision DAO and anthology DAO.
- Produces: `AnthologyBuildManifest` frozen from the project's current article revisions.

- [ ] **Step 1: Add project and manifest tests**

Cover:

```swift
@Test func createsProjectFromInboxSelectionInSelectionOrder() throws
@Test func reorderChangesSortOrderButNotStableSlot() throws
@Test func manifestFreezesExactCurrentRevisionIDs() throws
@Test func laterArticleEditMarksChangesAvailableWithoutChangingPriorBuild() throws
@Test func defaultsCreatorToVariousAuthorsOnlyAtBuildTime() throws
@Test func perEntryVoiceOverrideSurvivesReorder() throws
```

- [ ] **Step 2: Verify failure**

Run:

```bash
make test-only FILTER=EchoTests/AnthologyServiceTests
make test-only FILTER=EchoTests/AnthologyBuilderViewModelTests
```

Expected: missing service, manifest, and view model.

- [ ] **Step 3: Implement immutable build manifests**

```swift
struct AnthologyBuildManifest: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let anthologyID: UUID
    let revision: Int
    let epubIdentifier: String
    let title: String
    let subtitle: String?
    let creator: String
    let language: String
    let coverPath: String?
    let modifiedAt: Date
    let chapters: [AnthologyChapterManifest]
}

struct AnthologyChapterManifest: Codable, Equatable, Sendable {
    let entryID: UUID
    let captureID: UUID
    let articleRevisionID: UUID
    let stableSlot: Int
    let order: Int
    let title: String
    let author: String?
    let siteName: String?
    let sourceURL: URL
    let capturedAt: Date
    let voiceID: String?
    let blocks: [ArticleBlock]
    let readableContentSHA256: String
}
```

Use `urn:uuid:<anthology UUID>` for `epubIdentifier`. Build revision is latest successful revision + 1; a failed attempt does not consume the published revision.

- [ ] **Step 4: Implement builder UI**

Support metadata, generated/user cover choice, reordering by drag plus Move Up/Down accessibility actions, removal from project, per-article voice override, table-of-contents preview, and an in-context **Clean Up** route. Save each structural change immediately to the project; build remains explicit.

- [ ] **Step 5: Run focused tests**

Run:

```bash
make build-tests
make test-only FILTER=EchoTests/AnthologyServiceTests
make test-only FILTER=EchoTests/AnthologyBuilderViewModelTests
```

Expected: pass.

- [ ] **Step 6: Commit**

```bash
git add EchoCore/Services/ArticleWorkshop EchoCore/ViewModels/Anthology* EchoCore/Views/ArticleWorkshop Shared/ArticleWorkshop EchoTests/ArticleWorkshop
git commit -m "feat: author article anthology projects"
```

---

### Task 11: Build and preflight interoperable EPUB 3.3 files

**Files:**
- Create: `Shared/ArticleWorkshop/AnthologyCoverRenderer.swift`
- Create: `Shared/ArticleWorkshop/EPUBXMLWriter.swift`
- Create: `Shared/ArticleWorkshop/AnthologyEPUBBuilder.swift`
- Create: `Shared/ArticleWorkshop/AnthologyEPUBPreflight.swift`
- Test: `EchoTests/ArticleWorkshop/AnthologyEPUBBuilderTests.swift`
- Test: `EchoTests/ArticleWorkshop/AnthologyEPUBPreflightTests.swift`

**Interfaces:**
- Consumes: `AnthologyBuildManifest`.
- Produces: `AnthologyEPUBBuilder.build(manifest:to:) -> AnthologyEPUBBuildResult`.

- [ ] **Step 1: Add archive and escaping tests**

Assert:

- `mimetype` is first and uncompressed;
- container points to `EPUB/package.opf`;
- stable `dc:identifier` and changing `dcterms:modified`;
- nav order follows chapter order while chapter filenames use stable slots;
- every title/body/source string is escaped;
- source links exist but carry `data-echo-narration="skip"`;
- images are local manifest items;
- default cover is deterministic for fixed input;
- no absolute path or `..` entry is emitted.

- [ ] **Step 2: Verify failure**

Run:

```bash
make test-only FILTER=EchoTests/AnthologyEPUBBuilderTests
make test-only FILTER=EchoTests/AnthologyEPUBPreflightTests
```

Expected: missing builder.

- [ ] **Step 3: Implement XHTML and package serialization**

Each body block is emitted with:

```xml
<p id="echo-s7-b1004"
   data-echo-stable-slot="7"
   data-echo-block-index="1004">Escaped text</p>
```

Reserve stable block indices per chapter:

- `0` article title;
- `1` byline;
- `2` publication/site/date line;
- `1000 + ArticleBlock.stableOrdinal` body blocks;
- `900000` source/capture note.

Emit one `articles/article-s<stableSlot>.xhtml` per article. Spine and nav order use `chapter.order`; filenames and stable data use `stableSlot`.

- [ ] **Step 4: Implement ZIP creation and runtime preflight**

Use ZIPFoundation with `.none` compression for `mimetype`, then `.deflate` for the remaining entries. Assign every ZIP entry the manifest's `modifiedAt` timestamp instead of the current clock so identical manifests produce byte-identical archives. Write to a caller-provided temporary URL. Preflight reopens the archive and validates required paths, XML parseability, unique IDs/hrefs, spine/nav closure, declared assets/media types, safe relative paths, stable IDs, and package identifier.

`AnthologyEPUBBuildResult` contains URL, SHA-256, manifest SHA-256, identifier, and revision.

- [ ] **Step 5: Run focused tests**

Run:

```bash
make build-tests
make test-only FILTER=EchoTests/AnthologyEPUBBuilderTests
make test-only FILTER=EchoTests/AnthologyEPUBPreflightTests
```

Expected: pass.

- [ ] **Step 6: Commit**

```bash
git add Shared/ArticleWorkshop EchoTests/ArticleWorkshop
git commit -m "feat: build article anthology epubs"
```

---

### Task 12: Make EPUB builds atomic and import them as normal Echo books

**Files:**
- Create: `EchoCore/Services/ArticleWorkshop/AnthologyBuildService.swift`
- Modify: `EchoCore/Views/ArticleWorkshop/AnthologyDetailView.swift`
- Test: `EchoTests/ArticleWorkshop/AnthologyBuildServiceTests.swift`
- Test: `EchoTests/ArticleWorkshop/AnthologyLibraryIntegrationTests.swift`

**Interfaces:**
- Consumes: anthology service, EPUB builder/preflight, `AudiobookDAO`, `EPUBImportCoordinator`.
- Produces: a stable built edition at `ArticleWorkshop/Editions/<anthology UUID>/book.epub` and a Books shelf record.

- [ ] **Step 1: Add atomicity and import tests**

```swift
@Test func successfulBuildAtomicallyPublishesAndRecordsReady() async throws
@Test func failedRebuildRetainsPreviousEPUBAndSuccessfulReceipt() async throws
@Test func buildUsesOnlySnapshotFilesAndNeverCallsNetwork() async throws
@Test func importedAudiobookIdentityIsStableAcrossRebuilds() async throws
@Test func booksShelfMetadataUsesAnthologyTitleCreatorAndCover() async throws
```

Inject builder/import closures so failure paths do not require a full EPUB parser in every unit test; retain one real integration test through `EPUBImportCoordinator`.

- [ ] **Step 2: Verify failure**

Run:

```bash
make test-only FILTER=EchoTests/AnthologyBuildServiceTests
make test-only FILTER=EchoTests/AnthologyLibraryIntegrationTests
```

Expected: missing build service.

- [ ] **Step 3: Implement atomic build orchestration**

```swift
actor AnthologyBuildService {
    func build(anthologyID: UUID) async throws -> AnthologyBuildRecord
}
```

The service freezes a manifest, writes to `.book-<UUID>.epub`, preflights, SHA-256s, atomically replaces `book.epub`, upserts `AudiobookRecord` keyed by the stable edition directory URL, imports with explicit audiobook ID, then records the successful build. On any failure it records a failed attempt without replacing the prior file or latest-success pointer.

- [ ] **Step 4: Surface separate output status**

Anthology detail reports EPUB independently from narration and M4B:

```swift
enum AnthologyEPUBStatus {
    case notBuilt
    case building
    case ready(revision: Int)
    case changesAvailable(builtRevision: Int)
    case failed(previousRevision: Int?)
}
```

Provide **Build EPUB**, **Rebuild EPUB**, **Open in Echo**, and **Share EPUB** only when their prerequisites are true.

- [ ] **Step 5: Run focused tests**

Run:

```bash
make build-tests
make test-only FILTER=EchoTests/AnthologyBuildServiceTests
make test-only FILTER=EchoTests/AnthologyLibraryIntegrationTests
```

Expected: pass.

- [ ] **Step 6: Commit**

```bash
git add EchoCore/Services/ArticleWorkshop EchoCore/Views/ArticleWorkshop EchoTests/ArticleWorkshop
git commit -m "feat: import built anthologies into Echo"
```

---

### Task 13: Reconcile stable generated block identities

**Files:**
- Create: `Shared/Database/Migrations/Schema_V38.swift`
- Modify: `Shared/Database/DatabaseService.swift`
- Modify: `Shared/Database/EPubBlockRecord.swift`
- Modify: `Shared/EPUBXMLParsing.swift`
- Modify: `Shared/EPUBBlockParser.swift`
- Modify: `EchoCore/Services/EPUBImportService.swift`
- Create: `EchoCore/Services/ArticleWorkshop/GeneratedAnthologyImportIdentity.swift`
- Create: `EchoCore/Services/ArticleWorkshop/GeneratedAnthologyImportReconciler.swift`
- Modify: `EchoCore/Services/ArticleWorkshop/AnthologyBuildService.swift`
- Test: `EchoTests/ArticleWorkshop/SchemaV38GeneratedChapterKeyTests.swift`
- Test: `EchoTests/ArticleWorkshop/GeneratedAnthologyImportTests.swift`

**Interfaces:**
- Consumes: trusted in-memory `AnthologyBuildManifest`.
- Produces: stable `epub-<audiobookID>-s<stableSlot>-b<stableBlockIndex>` IDs and optional `sourceChapterKey`.

- [ ] **Step 1: Add reorder/rebuild preservation tests**

Seed notes, bookmarks, card color, hidden state, synthesized anchors, and word timing against article A/B blocks. Rebuild B/A and assert:

- block IDs unchanged;
- `spine_index`, `sequence_index`, and `chapter_index` reflect B/A;
- notes/bookmarks remain attached;
- user-owned visual/hidden fields remain when source text is unchanged;
- synthesized data remains for unchanged blocks;
- changed block text clears only its derived narration/alignment rows;
- removed blocks are deleted and cascade only their derived anchors.

- [ ] **Step 2: Verify failure**

Run:

```bash
make test-only FILTER=EchoTests/SchemaV38GeneratedChapterKeyTests
make test-only FILTER=EchoTests/GeneratedAnthologyImportTests
```

Expected: current parser generates order-based IDs and current import deletes every block.

- [ ] **Step 3: Add the V38 column and trusted identity map**

```swift
try db.alter(table: "epub_block") { table in
    table.add(column: "source_chapter_key", .text)
}
```

Add `sourceChapterKey: String?` to `EPubBlockRecord`. `TextBlockDescriptor` carries optional parsed Echo stable slot/block index, but `parseEPUBBlocks` uses it only when passed:

```swift
struct GeneratedAnthologyImportIdentity: Sendable {
    let anthologyID: UUID
    let expectedManifestSHA256: String
    let chaptersByHref: [String: GeneratedChapterIdentity]
}
```

Validate current internal manifest digest, expected package identifier, href membership, nonnegative stable slot, allowed reserved/body block ranges, and uniqueness before assigning stable IDs. Generic EPUB imports pass `nil` and keep current order-based IDs.

- [ ] **Step 4: Add reconcile persistence policy**

```swift
enum EPUBBlockPersistencePolicy: Sendable {
    case replaceAll
    case reconcileGenerated
}
```

For `reconcileGenerated`:

1. fetch existing blocks by ID;
2. preserve user-owned fields when kind/text are unchanged;
3. upsert incoming blocks without deleting matching rows;
4. clear synthesized anchors, word timings, and derived timeline rows only for changed IDs;
5. delete obsolete IDs after upsert;
6. replace TOC records;
7. perform all database changes in one transaction.

`AnthologyBuildService` passes the trusted identity and reconcile policy. No external EPUB import can request this policy.

- [ ] **Step 5: Run focused and generic importer regression tests**

Run:

```bash
make build-tests
make test-only FILTER=EchoTests/SchemaV38GeneratedChapterKeyTests
make test-only FILTER=EchoTests/GeneratedAnthologyImportTests
make test-only FILTER=EchoTests/EPUBBlockParserTests
make test-only FILTER=EchoTests/EPUBImportServiceTests
```

Expected: all pass; normal EPUB IDs remain unchanged.

- [ ] **Step 6: Commit**

```bash
git add Shared/Database Shared/EPUBXMLParsing.swift Shared/EPUBBlockParser.swift EchoCore/Services/EPUBImportService.swift EchoCore/Services/ArticleWorkshop EchoTests/ArticleWorkshop
git commit -m "feat: preserve anthology block identity"
```

---

### Task 14: Reuse narration across reorder and honor per-article voices

**Files:**
- Modify: `EchoCore/Services/Narration/NarrationChapterPlanner.swift`
- Modify: `EchoCore/Services/Narration/NarrationFileNaming.swift`
- Modify: `EchoCore/Services/Narration/NarrationService.swift`
- Modify: `EchoCore/ViewModels/PlayerModel+Narration.swift`
- Modify: `EchoCore/Services/Export/NarrationCacheSource.swift`
- Create: `EchoCore/Services/ArticleWorkshop/AnthologyNarrationStatusService.swift`
- Test: `EchoTests/ArticleWorkshop/AnthologyNarrationIdentityTests.swift`
- Modify tests: `EchoTests/NarrationFileNamingTests.swift`
- Modify tests: `EchoTests/NarrationExportDedupTests.swift`

**Interfaces:**
- Consumes: `EPubBlockRecord.sourceChapterKey`, anthology manifest voice/title data.
- Produces: stable cache/track identity for generated anthology chapters; legacy behavior for ordinary books.

- [ ] **Step 1: Add stable-key tests**

Prove:

```swift
@Test func stableChapterFilenameDoesNotContainCurrentOrdinal() throws
@Test func legacyChapterFilenameRemainsByteForByteUnchanged() throws
@Test func plannerUsesSourceChapterKeyButOrdersByCurrentSequence() throws
@Test func reorderReusesExistingAudioWithoutCallingTTS() async throws
@Test func changedTextOrVoiceMakesOnlyThatArticlePending() throws
@Test func defaultVoiceChangeDoesNotInvalidateExplicitOverrides() throws
@Test func exportOrdersPersistedTrackPathsByCurrentSortOrder() async throws
```

- [ ] **Step 2: Verify failure**

Run:

```bash
make test-only FILTER=EchoTests/AnthologyNarrationIdentityTests
make test-only FILTER=EchoTests/NarrationFileNamingTests
```

Expected: numeric chapter naming changes on reorder.

- [ ] **Step 3: Add optional stable chapter identity**

Extend planned chapters:

```swift
struct PlannedChapter: Equatable {
    let index: Int
    let displayNumber: Int
    let sourceChapterKey: String?
    let title: String
    let blocks: [EPubBlockRecord]
}
```

For generated chapters, all blocks in a chapter must share one `sourceChapterKey`; malformed mixed keys fall back to legacy index behavior and log a redacted warning.

Add:

```swift
static func chapterFileName(
    audiobookID: String,
    chapterIndex: Int,
    sourceChapterKey: String?,
    voice: VoiceID,
    contentSignature: String? = nil
) -> String
```

When `sourceChapterKey != nil`, name the file with `-ck<SHA256-prefix>` and no ordinal. Keep the current legacy format exactly when nil.

- [ ] **Step 4: Thread identity through rendering and playback**

`NarrationService.renderChapter` and segment APIs accept `sourceChapterKey: String? = nil`. Stable track IDs use a SHA-256 key suffix; `sortOrder` remains the current chapter index. Before synthesis, `PlayerModel+Narration` checks the expected stable filename/content signature/voice; a hit updates track title and order without calling TTS. Resolve voice from the anthology entry override or the current default and resolve track title as `Article Title — Author`.

`NarrationCacheSource.items()` first uses reachable narrated `TrackRecord.filePath` values ordered by `sort_order`; keep the current filename-glob path only as a legacy/recovery fallback.

- [ ] **Step 5: Add readiness calculation**

```swift
struct AnthologyNarrationStatus: Equatable, Sendable {
    let readyChapterCount: Int
    let totalChapterCount: Int
    let staleChapterKeys: [String]
    var isComplete: Bool { readyChapterCount == totalChapterCount }
}
```

Compute expected signature and effective voice for each current manifest chapter and compare with the persisted track/file. Do not infer readiness from “some narration tracks exist.”

- [ ] **Step 6: Run focused narration/export tests**

Run:

```bash
make build-tests
make test-only FILTER=EchoTests/AnthologyNarrationIdentityTests
make test-only FILTER=EchoTests/NarrationFileNamingTests
make test-only FILTER=EchoTests/NarrationExportDedupTests
make test-only FILTER=EchoTests/NarrationServiceTests
```

Expected: pass; existing books retain current filenames and behavior.

- [ ] **Step 7: Commit**

```bash
git add EchoCore/Services/Narration EchoCore/ViewModels/PlayerModel+Narration.swift EchoCore/Services/Export/NarrationCacheSource.swift EchoCore/Services/ArticleWorkshop EchoTests
git commit -m "feat: reuse anthology narration across rebuilds"
```

---

### Task 15: Add M4B readiness and anthology export

**Files:**
- Create: `EchoCore/Services/ArticleWorkshop/AnthologyM4BExportService.swift`
- Modify: `EchoCore/Views/ArticleWorkshop/AnthologyDetailView.swift`
- Test: `EchoTests/ArticleWorkshop/AnthologyOutputStatusTests.swift`
- Test: `EchoTests/ArticleWorkshop/AnthologyM4BExportTests.swift`

**Interfaces:**
- Consumes: latest successful build, narration status, `NarrationCacheSource`, `AudioExportService`.
- Produces: chaptered M4B with anthology metadata and article marker titles.

- [ ] **Step 1: Add output state and exporter tests**

Cover:

```swift
@Test func m4bWaitsUntilEveryCurrentChapterIsNarrated() throws
@Test func buildReadyDoesNotImplyM4BReady() throws
@Test func exportUsesAnthologyTitleCreatorCoverAndArticleMarkers() async throws
@Test func missingAuthorUsesArticleTitleOnly() async throws
@Test func failedExportDoesNotChangeNarrationOrEPUBReceipts() async throws
```

- [ ] **Step 2: Verify failure**

Run:

```bash
make test-only FILTER=EchoTests/AnthologyOutputStatusTests
make test-only FILTER=EchoTests/AnthologyM4BExportTests
```

Expected: missing status/export service.

- [ ] **Step 3: Implement the narrow exporter adapter**

```swift
actor AnthologyM4BExportService {
    func export(
        anthologyID: UUID,
        outputURL: URL
    ) async throws
}
```

Require latest build plus complete current narration. Resolve ordered items from persisted tracks, replace their marker titles from the frozen manifest, and call existing `AudioExportService.exportM4B`. Metadata:

- title/album = anthology title;
- artist/albumArtist = explicit creator or `Various Authors`;
- cover = built EPUB cover;
- marker = `Article Title — Author` or `Article Title`.

- [ ] **Step 4: Add independent status UI**

Anthology detail presents:

```text
EPUB        Ready · revision 3
Narration   5 of 7 chapters ready
M4B         Waiting for 2 chapters
```

Enable **Export M4B** only when the readiness service says complete. Use the existing iOS share sheet and macOS save-panel patterns; do not duplicate audio composition UI.

- [ ] **Step 5: Run focused and existing exporter tests**

Run:

```bash
make build-tests
make test-only FILTER=EchoTests/AnthologyOutputStatusTests
make test-only FILTER=EchoTests/AnthologyM4BExportTests
make test-only FILTER=EchoTests/AudioExportServiceTests
```

Expected: pass.

- [ ] **Step 6: Commit**

```bash
git add EchoCore/Services/ArticleWorkshop EchoCore/Views/ArticleWorkshop EchoTests/ArticleWorkshop
git commit -m "feat: export article anthologies as m4b"
```

---

### Task 16: Add private CloudKit records and `CKSyncEngine`

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

### Task 17: Wire sync lifecycle, settings, conflicts, and storage controls

**Files:**
- Create: `EchoCore/Services/ArticleWorkshop/ArticleWorkshopSyncCoordinator.swift`
- Modify: `EchoCore/Services/SettingsManager.swift`
- Modify: `EchoCore/Views/SettingsView.swift`
- Modify: `Echo macOS/Views/MacSettingsView.swift`
- Modify: iOS and macOS app lifecycle files
- Modify: `EchoCore/Info.plist`
- Create: `EchoCore/Views/ArticleWorkshop/ArticleWorkshopStorageView.swift`
- Modify: Article Inbox/detail/project views for sync/conflict status
- Test: `EchoTests/ArticleWorkshop/ArticleWorkshopSyncCoordinatorTests.swift`
- Test: `EchoTests/ArticleWorkshop/ArticleWorkshopStorageTests.swift`

**Interfaces:**
- Consumes: sync engine driver, DAOs, file store, SettingsManager.
- Produces: local-first lifecycle triggers, user control, recovered conflicts, and storage reporting.

- [ ] **Step 1: Add lifecycle and storage tests**

Cover:

```swift
@Test func syncDefaultsOnButLocalCaptureNeverWaitsForIt() async throws
@Test func disablingSyncStopsNewTransfersAndKeepsLocalData() async throws
@Test func foregroundRetriesOutboxAndFetchesChanges() async throws
@Test func accountLossShowsActionableStateWithoutDeletingWorkshop() async throws
@Test func conflictCopyHasStableRecoveredNameAndNewUUID() async throws
@Test func storageSummarySeparatesTextImagesEPUBNarrationAndM4B() async throws
@Test func deletingReferencedCaptureIsRefusedByDefault() async throws
```

- [ ] **Step 2: Verify failure**

Run:

```bash
make test-only FILTER=EchoTests/ArticleWorkshopSyncCoordinatorTests
make test-only FILTER=EchoTests/ArticleWorkshopStorageTests
```

Expected: missing coordinator/storage APIs.

- [ ] **Step 3: Add visible sync control and lifecycle**

Add `SettingsManager.articleWorkshopSyncEnabled`, default `true`. Settings copy:

```text
Sync Article Workshop
Privately sync article snapshots, edits, images, and anthology projects through your iCloud account. EPUB, narration, and M4B files stay on this device unless you export them.
```

Start the coordinator after database initialization. On launch/foreground and relevant local edits, schedule/send/fetch without blocking UI. Add `remote-notification` alongside `audio` in iOS background modes for silent CloudKit subscription pushes, and verify the resulting entitlements in an archive before release.

- [ ] **Step 4: Surface bounded, actionable states**

Use:

```swift
enum ArticleWorkshopSyncStatus: Equatable, Sendable {
    case localOnly
    case synced(Date)
    case waitingForNetwork
    case waitingForICloudAccount
    case quotaExceeded
    case conflict(count: Int)
    case failed(code: String)
}
```

Never show raw `CKError` text or article URLs. Conflicts offer **Review Versions** for article cleanup or open the recovered anthology copy. Turning sync off does not purge CloudKit or local data; destructive cloud deletion requires a separately confirmed future action and is not added here.

- [ ] **Step 5: Add storage controls**

Report capture package, image, EPUB, narration, and M4B sizes separately. Allow deletion of unreferenced Inbox captures and generated EPUBs; deleting a project does not delete reusable captures. Refuse referenced capture deletion until the user explicitly removes it from named anthologies.

- [ ] **Step 6: Run focused tests and platform builds**

Run:

```bash
make build-tests
make test-only FILTER=EchoTests/ArticleWorkshopSyncCoordinatorTests
make test-only FILTER=EchoTests/ArticleWorkshopStorageTests
xcodebuild build -project Echo.xcodeproj -scheme "Echo macOS" -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO -jobs 5
```

Expected: pass/build succeeds. This is not cross-device acceptance.

- [ ] **Step 7: Commit**

```bash
git add EchoCore/Services/SettingsManager.swift EchoCore/Services/ArticleWorkshop EchoCore/Views EchoCore/Info.plist "Echo macOS" EchoTests/ArticleWorkshop
git commit -m "feat: integrate article workshop sync"
```

---

### Task 18: Close security, accessibility, compatibility, and documentation gates

**Files:**
- Modify: `EchoCore/Localizable.xcstrings`
- Modify: `EchoCore/PrivacyInfo.xcprivacy`
- Modify: `Echo macOS/PrivacyInfo.xcprivacy`
- Create/modify: `Echo Share Extension/PrivacyInfo.xcprivacy`
- Create: `EchoTests/ArticleWorkshop/ArticleWorkshopSecurityTests.swift`
- Create: `EchoTests/ArticleWorkshop/ArticleWorkshopAccessibilityPolicyTests.swift`
- Create: `EchoTests/Fixtures/ArticleWorkshop/minimal-anthology.epub`
- Modify: `EchoTests/ArticleWorkshop/AnthologyEPUBBuilderTests.swift`
- Modify: `.github/workflows/ci.yml`
- Modify: `ARCHITECTURE.md`
- Modify: `README.md`
- Modify: `ROADMAP.md`
- Modify: `CHANGELOG.md`

**Interfaces:**
- Consumes: complete feature.
- Produces: release-quality automated gates and explicit manual acceptance matrix.

- [ ] **Step 1: Add adversarial whole-pipeline tests**

Exercise:

- script/form/frame/event-handler removal;
- XML external entities;
- `javascript:`, `file:`, path traversal, and malformed percent encoding;
- oversized HTML, too many blocks/images, oversized image, decompression bomb;
- spoofed Echo stable IDs on a generic EPUB;
- corrupt staging marker/digest;
- private text redaction in production log messages;
- failed rebuild retaining previous EPUB;
- malformed CloudKit records rejected before file/DB mutation.

- [ ] **Step 2: Add localization and accessibility policy tests**

Assert every Library mode, content state, cleanup action, move action, output state, sync state, and destructive confirmation has a localized key and non-color accessibility value. Add UI-level accessibility identifiers for manual VoiceOver/keyboard checks.

- [ ] **Step 3: Generate and lock the production EPUB fixture**

Build `minimal-anthology.epub` from a fixed manifest through `AnthologyEPUBBuilder`. Add a deterministic test that rebuilds with the fixed `modifiedAt` and byte-compares the output to the committed fixture, so the CI EPUBCheck artifact cannot drift away from production code.

Extend `.github/workflows/ci.yml` after unit tests:

```yaml
- name: Validate Article Workshop EPUB fixture
  run: |
    curl -fsSLo "$RUNNER_TEMP/epubcheck.zip" \
      https://github.com/w3c/epubcheck/releases/download/v5.3.0/epubcheck-5.3.0.zip
    echo "6c07e68584b2e2ce2f89fe06e1246dfead3eb36b46b340e7d93524f29dcff6c5  $RUNNER_TEMP/epubcheck.zip" \
      | shasum -a 256 -c -
    unzip -q "$RUNNER_TEMP/epubcheck.zip" -d "$RUNNER_TEMP/epubcheck"
    java -jar "$RUNNER_TEMP/epubcheck/epubcheck-5.3.0/epubcheck.jar" \
      EchoTests/Fixtures/ArticleWorkshop/minimal-anthology.epub
```

The literal SHA-256 above is the digest published on the official EPUBCheck 5.3.0 GitHub release asset.

- [ ] **Step 4: Update privacy, license, and product documentation**

Document:

- local rendered-page staging;
- private CloudKit zone distinct from public community anchors;
- no credentials, scripts, or silent refetch;
- Readability 0.6.0 and Apache-2.0 attribution;
- Books/Inbox/Anthologies;
- EPUB-first flow and existing M4B reuse;
- schema V37/V38/V39 and stable block/chapter identity;
- generated outputs not synced;
- separate acceptance receipts.

Review App Store privacy answers for user content stored in private iCloud. Do not claim legal redistribution rights.

- [ ] **Step 5: Run complete automated verification**

Run:

```bash
bash Scripts/verify_readability_vendor.sh
git diff --check
make build-tests
make test
xcodebuild build -project Echo.xcodeproj -scheme "Echo macOS" -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO -jobs 5
make echo-cli
epubcheck_cache="${TMPDIR:-/tmp}/echo-epubcheck-5.3.0"
mkdir -p "$epubcheck_cache"
curl -fsSLo "$epubcheck_cache/epubcheck.zip" \
  https://github.com/w3c/epubcheck/releases/download/v5.3.0/epubcheck-5.3.0.zip
echo "6c07e68584b2e2ce2f89fe06e1246dfead3eb36b46b340e7d93524f29dcff6c5  $epubcheck_cache/epubcheck.zip" \
  | shasum -a 256 -c -
unzip -qo "$epubcheck_cache/epubcheck.zip" -d "$epubcheck_cache"
java -jar "$epubcheck_cache/epubcheck-5.3.0/epubcheck.jar" \
  EchoTests/Fixtures/ArticleWorkshop/minimal-anthology.epub
git status --short --branch
```

Expected:

- pin check passes;
- no diff whitespace errors;
- EchoTests pass;
- iOS and macOS hosts, embedded share extension, and CLI build;
- EPUBCheck reports no errors;
- worktree contains only intentional tracked changes before the final commit.

- [ ] **Step 6: Perform explicit manual acceptance**

Record each result independently:

1. Safari capture on physical iPhone, iPad, and Mac.
2. Public, long, image-rich, malformed, offline-staged, and owner-authorized signed-in articles.
3. Text success with failed image fetch.
4. Capture on iPhone → private sync → cleanup/build on Mac.
5. Mac project reorder/edit → private sync → reflected on iPhone.
6. Offline edits followed by conflict recovery.
7. EPUB open/TOC/images/source links in Echo, Apple Books, Kobo, and Calibre.
8. Reorder after narration with proof that unchanged chapters did not synthesize again.
9. M4B chapters/cover/metadata in at least Apple Books and one additional chapter-aware player.
10. Full short-anthology listening pass.
11. VoiceOver on iPhone/iPad and keyboard/VoiceOver on Mac.

Do not convert an unrun item into a pass. File follow-up defects against the exact failed gate.

- [ ] **Step 7: Commit**

```bash
git add EchoCore/Localizable.xcstrings EchoCore/PrivacyInfo.xcprivacy "Echo macOS/PrivacyInfo.xcprivacy" "Echo Share Extension" EchoTests .github/workflows/ci.yml ARCHITECTURE.md README.md ROADMAP.md CHANGELOG.md
git commit -m "docs: close article workshop release gates"
```

- [ ] **Step 8: Final branch verification and publication**

Run:

```bash
git status --short --branch
git log --oneline origin/nightly..HEAD
```

Expected: clean feature worktree and coherent conventional commits. If implementation was requested through completion, push the feature branch, open a ready PR against `nightly`, and report hosted CI as pending/passing/failing separately from local, device, compatibility, and listening acceptance.

---

## Milestone receipts

After Task 7: local Safari capture → durable Inbox is usable on iOS.

After Task 9: snapshots can be structurally cleaned and reset without mutation.

After Task 12: ordered articles build and import as an interoperable EPUB.

After Task 15: unchanged narration survives reorder and complete anthologies export as chaptered M4B.

After Task 17: captures, revisions, images, and projects sync privately across Apple devices.

After Task 18: security, accessibility, format compatibility, documentation, and real-device/listening gates are reported independently.
