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
