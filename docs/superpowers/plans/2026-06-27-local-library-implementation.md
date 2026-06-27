# On-Device Library Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an on-device Library — a launcher layer above Echo's single-book player that lists every added book, browses it by several axes, and rescans registered folder "roots" — without changing playback.

**Architecture:** New code is concrete and constructor/closure-injected (the `DatabaseService(inMemory:)` house pattern — no protocols). A V27 migration adds library columns to `audiobook` and a `library_root` table. A `LibraryScanner` discovers books under a root and does a cheap metadata read; a `LibraryService` registers roots, rescans, lists/groups books, computes availability, and resolves a book's URL for opening (which then calls the existing `PlayerModel.loadFolder(url:)`). The UI (Library tab, smart-landing, roots/missing-file management) is Milestones 3–4.

**Tech Stack:** Swift 6, SwiftUI, GRDB (SQLite), AVFoundation, Swift Testing, os.Logger.

## Global Constraints

- **SPDX header:** every Swift file starts with `// SPDX-License-Identifier: GPL-3.0-or-later` on line 1. (A PostToolUse SwiftFormat hook can reflow imports — verify the SPDX line stays line 1 after edits.)
- **DB column naming:** `snake_case` columns mapped via `CodingKeys` to camelCase Swift properties.
- **Migration registration is append-only and never reordered:** add exactly one `migrator.registerMigration("v27_library")` after `"v26_timeline_segment_key"` (the current last migration).
- **No protocols for the new services** — inject `DatabaseWriter`/`DatabaseService` or closures; create DAOs from the writer.
- **Logging:** `private let logger = Logger(category: "Name")`; use `logger.info/.warning/.error`; raw `print()` only behind `#if DEBUG`.
- **Concurrency:** Swift 6 language mode is on (PR #195). New view models/stores that touch UI are `@MainActor`; pure value services are plain structs. Use `async/await`, never `DispatchQueue.main.async` or blocking sleeps.
- **Tests:** Swift Testing (`@Test`, `@MainActor @Suite struct`, `#expect`). Build once with `make build-tests` (needs `CODE_SIGNING_ALLOWED=NO`), then `make test-only FILTER=EchoTests/<Suite>`. UI tests stay excluded from the scheme.
- **iOS-first:** all new files live in `Shared/` or `EchoCore/` so macOS can adopt them later; do **not** wire macOS UI in this plan.
- **Migration number = V27 (confirmed).** V26 is already taken on `nightly` by `v26_timeline_segment_key` (merged); the PDF Alignment initiative separately contends for a number. The Library therefore uses **V27** (`v27_library` / `Schema_V27`). Before Task 1, re-confirm `v27_*` is still free against `DatabaseService.runMigrations`; if a newer migration has landed, bump to the next free number everywhere in this plan and STOP to flag it.

## Refinements vs. the spec (read before starting)

The spec (`docs/superpowers/specs/2026-06-26-local-library-design.md`) is authoritative on behavior. Two realizations during interface extraction refine the *mechanism*:

1. **The spec's "`BookmarkStore`" is renamed.** `BookmarkStore` already exists in the codebase (it manages the user's saved bookmarks + voice memos — unrelated). The security-scoped folder access is realized instead as: root bookmarks stored in the new **`library_root.bookmark`** BLOB column, resolved by a small **`LibraryAccess`** helper. There is **no per-book bookmark store** — because every library book is reached through a root (and Component D auto-registers any picker folder as a root), one root bookmark unlocks all its books.
2. **There is no standard `TabView`.** Tabs are a custom `UnifiedBottomDock` + `BottomToolbarView` chip toggling `model.selectedTab`. The Library destination is added there (Milestone 3).

---

## File Structure

**Milestone 1 — Data + access foundation**
- Create `Shared/Database/Migrations/Schema_V27.swift` — adds library columns + `library_root` table + indexes.
- Modify `Shared/Database/DatabaseService.swift` — register `v27_library`.
- Modify `Shared/Database/DAOs/AudiobookDAO.swift` — add 7 library fields + `CodingKeys` to `AudiobookRecord`.
- Create `Shared/Database/DAOs/LibraryRootDAO.swift` — `LibraryRootRecord` + `LibraryRootDAO`.
- Create `EchoCore/Services/Library/LibraryAccess.swift` — bookmark make/resolve + `authorSort` normalization.
- Test: `EchoTests/SchemaV27Tests.swift`, `EchoTests/AudiobookRecordLibraryFieldsTests.swift`, `EchoTests/LibraryRootDAOTests.swift`, `EchoTests/LibraryAccessTests.swift`.

**Milestone 2 — Scan + service**
- Create `EchoCore/Services/Library/LibraryScanner.swift` — recursive book discovery + cheap metadata read.
- Create `EchoCore/Services/Library/LibraryService.swift` — register root, rescan, list/group, availability, derived status, `urlForOpening`.
- Test: `EchoTests/LibraryScannerTests.swift`, `EchoTests/LibraryServiceTests.swift`.

**Milestones 3–4 — UI/nav, roots & missing-file UI** (roadmap at the end; to be expanded into their own plan once M1–M2 land).

---

## Milestone 1 — Data + Access Foundation

### Task 1: V27 migration (library columns + `library_root` table)

**Files:**
- Create: `Shared/Database/Migrations/Schema_V27.swift`
- Modify: `Shared/Database/DatabaseService.swift` (the `runMigrations` block — register after `v26_timeline_segment_key`, the current last migration)
- Test: `EchoTests/SchemaV27Tests.swift`

**Interfaces:**
- Produces: `enum Schema_V27 { nonisolated static func migrate(_ db: Database) throws }`; new `audiobook` columns `cover_art_path, narrator, index_state, is_available, last_seen_at, author_sort, source_root_id`; new table `library_root(id, display_name, bookmark, added_at, last_scanned_at)`.

- [ ] **Step 1: Write the failing test**

Create `EchoTests/SchemaV27Tests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct SchemaV27Tests {
    @Test func v27AddsLibraryColumnsToAudiobook() throws {
        let db = try DatabaseService(inMemory: ())
        let columns = try columnNames(table: "audiobook", db: db)

        #expect(columns.contains("cover_art_path"))
        #expect(columns.contains("narrator"))
        #expect(columns.contains("index_state"))
        #expect(columns.contains("is_available"))
        #expect(columns.contains("last_seen_at"))
        #expect(columns.contains("author_sort"))
        #expect(columns.contains("source_root_id"))
    }

    @Test func v27CreatesLibraryRootTable() throws {
        let db = try DatabaseService(inMemory: ())
        let columns = try columnNames(table: "library_root", db: db)

        #expect(columns.contains("id"))
        #expect(columns.contains("display_name"))
        #expect(columns.contains("bookmark"))
        #expect(columns.contains("added_at"))
        #expect(columns.contains("last_scanned_at"))
    }

    @Test func v27CreatesLibraryIndexes() throws {
        let db = try DatabaseService(inMemory: ())
        let indexes = try indexNames(table: "audiobook", db: db)
        #expect(indexes.contains("idx_audiobook_author_sort"))
        #expect(indexes.contains("idx_audiobook_available_added"))
        #expect(indexes.contains("idx_audiobook_source_root"))
    }

    @Test func existingAudiobookRowsDefaultSanely() throws {
        let db = try DatabaseService(inMemory: ())
        try db.writer.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('b1', 'T', 3600)")
        }
        let row = try db.writer.read { db in
            try Row.fetchOne(
                db, sql: "SELECT index_state, is_available FROM audiobook WHERE id = 'b1'")
        }
        #expect(row?["index_state"] as? Int64 == 0)
        #expect(row?["is_available"] as? Int64 == 1)
    }

    private func columnNames(table: String, db: DatabaseService) throws -> Set<String> {
        try db.read { database in
            let rows = try Row.fetchAll(database, sql: "PRAGMA table_info(\(table))")
            return Set(rows.compactMap { $0["name"] as? String })
        }
    }

    private func indexNames(table: String, db: DatabaseService) throws -> Set<String> {
        try db.read { database in
            let rows = try Row.fetchAll(database, sql: "PRAGMA index_list(\(table))")
            return Set(rows.compactMap { $0["name"] as? String })
        }
    }
}
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `make build-tests CODE_SIGNING_ALLOWED=NO && make test-only FILTER=EchoTests/SchemaV27Tests`
Expected: FAIL — compile error "cannot find 'Schema_V27'" (it isn't registered yet) / missing columns.

- [ ] **Step 3: Create the migration**

Create `Shared/Database/Migrations/Schema_V27.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

/// V27 — On-device Library: browsable shelf metadata on `audiobook` plus a
/// `library_root` table of registered, rescannable folders.
///
/// Additive only: new nullable columns (and two NOT NULL columns with defaults,
/// safe for SQLite `ALTER TABLE ADD COLUMN`), a new table, and indexes. Does not
/// edit shipped migrations and does not force an EPUB re-import or re-alignment.
enum Schema_V27 {
    nonisolated static func migrate(_ db: Database) throws {
        try db.alter(table: "audiobook") { t in
            t.add(column: "cover_art_path", .text)
            t.add(column: "narrator", .text)
            t.add(column: "index_state", .integer).notNull().defaults(to: 0)
            t.add(column: "is_available", .boolean).notNull().defaults(to: true)
            t.add(column: "last_seen_at", .text)
            t.add(column: "author_sort", .text)
            // Plain column (no hard FK): root-removal clears it manually, and
            // SQLite can't add a FK constraint via ALTER TABLE ADD COLUMN.
            t.add(column: "source_root_id", .text)
        }

        try db.create(table: "library_root", ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("display_name", .text).notNull()
            t.column("bookmark", .blob).notNull()
            t.column("added_at", .text).notNull()
            t.column("last_scanned_at", .text)
        }

        try db.create(
            index: "idx_audiobook_author_sort",
            on: "audiobook", columns: ["author_sort"], ifNotExists: true)
        try db.create(
            index: "idx_audiobook_available_added",
            on: "audiobook", columns: ["is_available", "added_at"], ifNotExists: true)
        try db.create(
            index: "idx_audiobook_source_root",
            on: "audiobook", columns: ["source_root_id"], ifNotExists: true)
    }
}
```

- [ ] **Step 4: Register the migration**

In `Shared/Database/DatabaseService.swift`, inside `runMigrations`, add the registration immediately after the `v26_timeline_segment_key` block (the current last migration — do not reorder, do not touch earlier migrations):

```swift
    migrator.registerMigration("v26_timeline_segment_key") { db in
        try Schema_V26.migrate(db)
    }
    migrator.registerMigration("v27_library") { db in
        try Schema_V27.migrate(db)
    }
    try migrator.migrate(writer)
```

- [ ] **Step 5: Run the test, verify it passes**

Run: `make build-tests CODE_SIGNING_ALLOWED=NO && make test-only FILTER=EchoTests/SchemaV27Tests`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add Shared/Database/Migrations/Schema_V27.swift Shared/Database/DatabaseService.swift EchoTests/SchemaV27Tests.swift
git commit -m "feat(db): V27 migration — library columns + library_root table"
```

---

### Task 2: `AudiobookRecord` library fields

**Files:**
- Modify: `Shared/Database/DAOs/AudiobookDAO.swift:49-72` (the `AudiobookRecord` struct + `CodingKeys`)
- Test: `EchoTests/AudiobookRecordLibraryFieldsTests.swift`

**Interfaces:**
- Produces: `AudiobookRecord` gains `coverArtPath: String?`, `narrator: String?`, `indexState: Int = 0`, `isAvailable: Bool = true`, `lastSeenAt: String?`, `authorSort: String?`, `sourceRootID: String?` (all with defaults, so existing call sites in `ABSImportService` / `TimelineIngestionService` still compile).

- [ ] **Step 1: Write the failing test**

Create `EchoTests/AudiobookRecordLibraryFieldsTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB
import Testing

@testable import Echo

@MainActor
struct AudiobookRecordLibraryFieldsTests {
    @Test func libraryFieldsRoundTripThroughSQLite() throws {
        let db = try DatabaseService(inMemory: ())
        let record = AudiobookRecord(
            id: "file:///Books/Dune/",
            title: "Dune",
            author: "Frank Herbert",
            duration: 1234,
            fileCount: 1,
            addedAt: "2026-06-27T00:00:00Z",
            coverArtPath: "covers/dune.jpg",
            narrator: "Scott Brick",
            indexState: 0,
            isAvailable: true,
            lastSeenAt: "2026-06-27T00:00:00Z",
            authorSort: "frank herbert",
            sourceRootID: "root-1")
        try AudiobookDAO(db: db.writer).save(record)

        let fetched = try AudiobookDAO(db: db.writer).get("file:///Books/Dune/")
        #expect(fetched?.coverArtPath == "covers/dune.jpg")
        #expect(fetched?.narrator == "Scott Brick")
        #expect(fetched?.indexState == 0)
        #expect(fetched?.isAvailable == true)
        #expect(fetched?.authorSort == "frank herbert")
        #expect(fetched?.sourceRootID == "root-1")
    }

    @Test func defaultsApplyWhenLibraryFieldsOmitted() throws {
        let record = AudiobookRecord(
            id: "b", title: "T", author: nil, duration: 0, fileCount: nil,
            addedAt: "2026-06-27T00:00:00Z")
        #expect(record.indexState == 0)
        #expect(record.isAvailable == true)
        #expect(record.coverArtPath == nil)
        #expect(record.sourceRootID == nil)
    }
}
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `make build-tests CODE_SIGNING_ALLOWED=NO && make test-only FILTER=EchoTests/AudiobookRecordLibraryFieldsTests`
Expected: FAIL — compile error "extra arguments 'coverArtPath', …" (the struct lacks these members).

- [ ] **Step 3: Add the fields**

In `Shared/Database/DAOs/AudiobookDAO.swift`, extend `AudiobookRecord`. Add the new stored properties after `topicsJSON` and the new `CodingKeys` after `topicsJSON`:

```swift
    var topicsJSON: String? = nil
    var coverArtPath: String? = nil
    var narrator: String? = nil
    var indexState: Int = 0
    var isAvailable: Bool = true
    var lastSeenAt: String? = nil
    var authorSort: String? = nil
    var sourceRootID: String? = nil

    static let databaseTableName = "audiobook"

    enum CodingKeys: String, CodingKey {
        case id, title, author, duration
        case fileCount = "file_count"
        case addedAt = "added_at"
        case sourceType = "source_type"
        case serverID = "server_id"
        case remoteItemID = "remote_item_id"
        case topicsJSON = "topics_json"
        case coverArtPath = "cover_art_path"
        case narrator
        case indexState = "index_state"
        case isAvailable = "is_available"
        case lastSeenAt = "last_seen_at"
        case authorSort = "author_sort"
        case sourceRootID = "source_root_id"
    }
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `make build-tests CODE_SIGNING_ALLOWED=NO && make test-only FILTER=EchoTests/AudiobookRecordLibraryFieldsTests`
Expected: PASS (2 tests). Also re-run `EchoTests/SchemaV25Tests` and a build of the full app target to confirm `ABSImportService`/`TimelineIngestionService` still compile (defaults preserve their call sites).

- [ ] **Step 5: Commit**

```bash
git add Shared/Database/DAOs/AudiobookDAO.swift EchoTests/AudiobookRecordLibraryFieldsTests.swift
git commit -m "feat(db): add Library metadata fields to AudiobookRecord"
```

---

### Task 3: `LibraryRootRecord` + `LibraryRootDAO`

**Files:**
- Create: `Shared/Database/DAOs/LibraryRootDAO.swift`
- Test: `EchoTests/LibraryRootDAOTests.swift`

**Interfaces:**
- Produces: `struct LibraryRootRecord: Codable, FetchableRecord, MutablePersistableRecord { var id: String; var displayName: String; var bookmark: Data; var addedAt: String; var lastScannedAt: String? }` and `struct LibraryRootDAO { init(db: DatabaseWriter); func all() throws -> [LibraryRootRecord]; func get(_ id: String) throws -> LibraryRootRecord?; func save(_ root: LibraryRootRecord) throws; func delete(id: String) throws }`.

- [ ] **Step 1: Write the failing test**

Create `EchoTests/LibraryRootDAOTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
struct LibraryRootDAOTests {
    @Test func savesFetchesAndDeletesRoots() throws {
        let db = try DatabaseService(inMemory: ())
        let dao = LibraryRootDAO(db: db.writer)

        let root = LibraryRootRecord(
            id: "root-1", displayName: "Audiobooks",
            bookmark: Data([0x01, 0x02]), addedAt: "2026-06-27T00:00:00Z",
            lastScannedAt: nil)
        try dao.save(root)

        #expect(try dao.get("root-1")?.displayName == "Audiobooks")
        #expect(try dao.all().count == 1)

        try dao.delete(id: "root-1")
        #expect(try dao.get("root-1") == nil)
    }

    @Test func allReturnsRootsNewestFirst() throws {
        let db = try DatabaseService(inMemory: ())
        let dao = LibraryRootDAO(db: db.writer)
        try dao.save(LibraryRootRecord(
            id: "a", displayName: "A", bookmark: Data(), addedAt: "2026-06-01T00:00:00Z",
            lastScannedAt: nil))
        try dao.save(LibraryRootRecord(
            id: "b", displayName: "B", bookmark: Data(), addedAt: "2026-06-27T00:00:00Z",
            lastScannedAt: nil))
        #expect(try dao.all().map(\.id) == ["b", "a"])
    }
}
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `make build-tests CODE_SIGNING_ALLOWED=NO && make test-only FILTER=EchoTests/LibraryRootDAOTests`
Expected: FAIL — "cannot find 'LibraryRootDAO'".

- [ ] **Step 3: Create the DAO**

Create `Shared/Database/DAOs/LibraryRootDAO.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

/// A user-registered folder that the Library rescans for books. Stores the
/// security-scoped bookmark so the folder (and recursively its children) can be
/// reopened across launches.
struct LibraryRootRecord: Codable, FetchableRecord, MutablePersistableRecord {
    var id: String
    var displayName: String
    var bookmark: Data
    var addedAt: String
    var lastScannedAt: String?

    static let databaseTableName = "library_root"

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case bookmark
        case addedAt = "added_at"
        case lastScannedAt = "last_scanned_at"
    }
}

struct LibraryRootDAO {
    private let db: DatabaseWriter

    init(db: DatabaseWriter) {
        self.db = db
    }

    func all() throws -> [LibraryRootRecord] {
        try db.read { db in
            try LibraryRootRecord.order(Column("added_at").desc).fetchAll(db)
        }
    }

    func get(_ id: String) throws -> LibraryRootRecord? {
        try db.read { db in try LibraryRootRecord.fetchOne(db, key: id) }
    }

    func save(_ root: LibraryRootRecord) throws {
        var copy = root
        try db.write { db in try copy.save(db) }
    }

    func delete(id: String) throws {
        _ = try db.write { db in try LibraryRootRecord.deleteOne(db, key: id) }
    }
}
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `make build-tests CODE_SIGNING_ALLOWED=NO && make test-only FILTER=EchoTests/LibraryRootDAOTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add Shared/Database/DAOs/LibraryRootDAO.swift EchoTests/LibraryRootDAOTests.swift
git commit -m "feat(db): add LibraryRootRecord + LibraryRootDAO"
```

---

### Task 4: `LibraryAccess` — bookmark resolution + author normalization

**Files:**
- Create: `EchoCore/Services/Library/LibraryAccess.swift`
- Test: `EchoTests/LibraryAccessTests.swift`

**Interfaces:**
- Produces: `enum LibraryAccess { static func makeBookmark(for url: URL) -> Data?; static func resolveURL(from data: Data) -> (url: URL, isStale: Bool)?; static func authorSort(_ author: String?) -> String? }`. Mirrors `Persistence.saveBookmark`/`restoreBookmark` bookmark options (`options: []`), but pure/static so it's testable with plain file URLs.

- [ ] **Step 1: Write the failing test**

Create `EchoTests/LibraryAccessTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
struct LibraryAccessTests {
    @Test func bookmarkRoundTripsToSameFolder() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lib-access-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let data = try #require(LibraryAccess.makeBookmark(for: tmp))
        let resolved = try #require(LibraryAccess.resolveURL(from: data))
        #expect(resolved.url.standardizedFileURL.path == tmp.standardizedFileURL.path)
    }

    @Test func authorSortNormalizesCommaForm() {
        #expect(LibraryAccess.authorSort("Tolkien, J.R.R.") == "j.r.r. tolkien")
        #expect(LibraryAccess.authorSort("  Frank Herbert ") == "frank herbert")
        #expect(LibraryAccess.authorSort(nil) == nil)
        #expect(LibraryAccess.authorSort("") == nil)
    }
}
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `make build-tests CODE_SIGNING_ALLOWED=NO && make test-only FILTER=EchoTests/LibraryAccessTests`
Expected: FAIL — "cannot find 'LibraryAccess'".

- [ ] **Step 3: Create the helper**

Create `EchoCore/Services/Library/LibraryAccess.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import os.log

/// Security-scoped bookmark make/resolve for Library roots, plus author-sort
/// normalization. Pure/static so it is testable with plain file URLs and shared
/// by iOS and (later) macOS. Mirrors `Persistence`'s bookmark options.
enum LibraryAccess {
    private static let logger = Logger(category: "LibraryAccess")

    /// Creates a persistent bookmark for `url` (a folder root). Empty options =
    /// a full bookmark that survives relaunch, matching `Persistence.saveBookmark`.
    static func makeBookmark(for url: URL) -> Data? {
        do {
            return try url.bookmarkData(
                options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            logger.error("Bookmark create failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Resolves bookmark `data` back to a URL, reporting staleness. Returns nil if
    /// the bookmark can no longer be resolved (the root is unavailable).
    static func resolveURL(from data: Data) -> (url: URL, isStale: Bool)? {
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data, options: [], relativeTo: nil,
                bookmarkDataIsStale: &isStale)
            return (url, isStale)
        } catch {
            logger.error("Bookmark resolve failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Best-effort normalized grouping key for "browse by author": trims, flips a
    /// single "Last, First" into "First Last", lowercases. Display uses the raw
    /// author; this only groups. Returns nil for nil/empty input.
    static func authorSort(_ author: String?) -> String? {
        guard let trimmed = author?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else { return nil }

        let parts = trimmed.split(separator: ",", maxSplits: 1).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        let canonical = parts.count == 2 ? "\(parts[1]) \(parts[0])" : trimmed
        return canonical.lowercased()
    }
}
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `make build-tests CODE_SIGNING_ALLOWED=NO && make test-only FILTER=EchoTests/LibraryAccessTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/Library/LibraryAccess.swift EchoTests/LibraryAccessTests.swift
git commit -m "feat(library): add LibraryAccess bookmark + author-sort helpers"
```

---

## Milestone 2 — Scan + Service

### Task 5: `LibraryScanner` — recursive book discovery

**Files:**
- Create: `EchoCore/Services/Library/LibraryScanner.swift`
- Test: `EchoTests/LibraryScannerTests.swift`

**Interfaces:**
- Produces: `struct DiscoveredBook: Equatable { let folderURL: URL; let audioFiles: [URL]; let companionEPUB: URL? }` and `enum LibraryScanner { static func discoverBooks(in root: URL) -> [DiscoveredBook] }`. A "book" = a directory that directly contains ≥1 audio file; `folderURL` is that directory (the same identity key `loadFolder` uses). Mirrors `FolderAudioScanner`'s enumerator options + companion-EPUB lookup.

- [ ] **Step 1: Write the failing test**

Create `EchoTests/LibraryScannerTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor
struct LibraryScannerTests {
    /// Builds: root/BookA/a.m4b, root/BookA/a.epub, root/Series/BookB/b.mp3,
    /// root/notes.txt (ignored). Expect two books, BookB carrying no EPUB.
    private func makeTree() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("lib-scan-\(UUID().uuidString)", isDirectory: true)
        let bookA = root.appendingPathComponent("BookA", isDirectory: true)
        let bookB = root.appendingPathComponent("Series/BookB", isDirectory: true)
        try fm.createDirectory(at: bookA, withIntermediateDirectories: true)
        try fm.createDirectory(at: bookB, withIntermediateDirectories: true)
        try Data().write(to: bookA.appendingPathComponent("a.m4b"))
        try Data().write(to: bookA.appendingPathComponent("a.epub"))
        try Data().write(to: bookB.appendingPathComponent("b.mp3"))
        try Data().write(to: root.appendingPathComponent("notes.txt"))
        return root
    }

    @Test func discoversOneBookPerAudioFolder() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let books = LibraryScanner.discoverBooks(in: root)
        let names = books.map { $0.folderURL.lastPathComponent }.sorted()
        #expect(names == ["BookA", "BookB"])
    }

    @Test func attachesCompanionEPUBWhenPresent() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(at: root) }

        let books = LibraryScanner.discoverBooks(in: root)
        let bookA = try #require(books.first { $0.folderURL.lastPathComponent == "BookA" })
        let bookB = try #require(books.first { $0.folderURL.lastPathComponent == "BookB" })
        #expect(bookA.companionEPUB?.lastPathComponent == "a.epub")
        #expect(bookB.companionEPUB == nil)
    }
}
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `make build-tests CODE_SIGNING_ALLOWED=NO && make test-only FILTER=EchoTests/LibraryScannerTests`
Expected: FAIL — "cannot find 'LibraryScanner'".

- [ ] **Step 3: Create the scanner**

Create `EchoCore/Services/Library/LibraryScanner.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// A book discovered under a Library root: the folder that directly holds its
/// audio, its audio files, and a companion EPUB if one sits beside them.
struct DiscoveredBook: Equatable {
    let folderURL: URL
    let audioFiles: [URL]
    let companionEPUB: URL?
}

/// Recursively finds books under a root by grouping audio files by their parent
/// folder. One folder containing audio == one book (a lone `.m4b`'s folder is its
/// book). Mirrors `FolderAudioScanner`'s enumerator options.
enum LibraryScanner {
    private static let audioExtensions: Set<String> = ["m4b", "mp3", "m4a", "aax", "wav", "flac"]

    static func discoverBooks(in root: URL) -> [DiscoveredBook] {
        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants])

        var audioByFolder: [URL: [URL]] = [:]
        while let url = enumerator?.nextObject() as? URL {
            guard audioExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let folder = url.deletingLastPathComponent().standardizedFileURL
            audioByFolder[folder, default: []].append(url)
        }

        return audioByFolder.keys.sorted { $0.path < $1.path }.map { folder in
            DiscoveredBook(
                folderURL: folder,
                audioFiles: audioByFolder[folder]!.sorted { $0.path < $1.path },
                companionEPUB: companionEPUB(in: folder))
        }
    }

    private static func companionEPUB(in folder: URL) -> URL? {
        let siblings = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? []
        return siblings.first { $0.pathExtension.lowercased() == "epub" }
    }
}
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `make build-tests CODE_SIGNING_ALLOWED=NO && make test-only FILTER=EchoTests/LibraryScannerTests`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/Library/LibraryScanner.swift EchoTests/LibraryScannerTests.swift
git commit -m "feat(library): add LibraryScanner book discovery"
```

---

### Task 6: `LibraryScanner` — cheap metadata read

**Files:**
- Modify: `EchoCore/Services/Library/LibraryScanner.swift`
- Test: `EchoTests/LibraryScannerTests.swift` (add cases)

**Interfaces:**
- Produces: `struct ScannedMetadata: Equatable { var title: String; var author: String?; var narrator: String?; var duration: TimeInterval; var coverImageData: Data? }`; `static func fallbackTitle(for book: DiscoveredBook) -> String`; `static func readMetadata(for book: DiscoveredBook) async -> ScannedMetadata`. `readMetadata` loads `AVURLAsset.load(.commonMetadata)` (title/author/artwork) + `.duration` for the first audio file, falling back to the folder name; cover via `ArtworkCache.embeddedArtworkImage` then `ArtworkCache.folderArtworkImage`.

- [ ] **Step 1: Write the failing test (deterministic fallback only)**

Add to `EchoTests/LibraryScannerTests.swift`:

```swift
    @Test func fallbackTitleUsesFolderName() throws {
        let book = DiscoveredBook(
            folderURL: URL(fileURLWithPath: "/Books/The Hobbit", isDirectory: true),
            audioFiles: [URL(fileURLWithPath: "/Books/The Hobbit/01.m4b")],
            companionEPUB: nil)
        #expect(LibraryScanner.fallbackTitle(for: book) == "The Hobbit")
    }
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `make build-tests CODE_SIGNING_ALLOWED=NO && make test-only FILTER=EchoTests/LibraryScannerTests`
Expected: FAIL — "cannot find 'fallbackTitle'".

- [ ] **Step 3: Add metadata reading**

Append to `LibraryScanner` in `EchoCore/Services/Library/LibraryScanner.swift`:

```swift
import AVFoundation
import CryptoKit

extension LibraryScanner {
    struct ScannedMetadata: Equatable {
        var title: String
        var author: String?
        var narrator: String?
        var duration: TimeInterval
        var coverImageData: Data?
    }

    static func fallbackTitle(for book: DiscoveredBook) -> String {
        book.folderURL.lastPathComponent
    }

    /// Cheap per-book metadata read for the shelf — title/author/duration/cover
    /// only. No chapter parsing, EPUB extraction, or alignment (those run on first
    /// open). Falls back to the folder name when audio carries no title.
    static func readMetadata(for book: DiscoveredBook) async -> ScannedMetadata {
        guard let first = book.audioFiles.first else {
            return ScannedMetadata(
                title: fallbackTitle(for: book), author: nil, narrator: nil,
                duration: 0, coverImageData: nil)
        }
        let asset = AVURLAsset(url: first)
        let metadata = (try? await asset.load(.commonMetadata)) ?? []

        let title = await stringValue(in: metadata, key: .commonKeyTitle)
        let author = await stringValue(in: metadata, key: .commonKeyArtist)
        let duration = ((try? await asset.load(.duration))?.seconds).flatMap {
            $0.isFinite ? $0 : nil
        } ?? 0

        var cover: Data? = nil
        if let image = await ArtworkCache.embeddedArtworkImage(for: first)
            ?? ArtworkCache.folderArtworkImage(near: first) {
            cover = image.jpegData(compressionQuality: 0.8)
        }

        return ScannedMetadata(
            title: title?.isEmpty == false ? title! : fallbackTitle(for: book),
            author: author, narrator: nil, duration: duration, coverImageData: cover)
    }

    private static func stringValue(
        in metadata: [AVMetadataItem], key: AVMetadataKey
    ) async -> String? {
        guard let item = metadata.first(where: { $0.commonKey?.rawValue == key.rawValue })
        else { return nil }
        return try? await item.load(.stringValue)
    }
}
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `make build-tests CODE_SIGNING_ALLOWED=NO && make test-only FILTER=EchoTests/LibraryScannerTests`
Expected: PASS (fallback test). **Manual/integration step:** the `AVURLAsset` path needs a real media fixture; verify in Milestone 2 end-to-end (Task 8) by registering a folder of real `.m4b` files on the simulator and confirming titles/covers populate. Log a one-line note in the PR that the AV path is integration-verified, not unit-tested (no audio fixtures in the test bundle).

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/Library/LibraryScanner.swift EchoTests/LibraryScannerTests.swift
git commit -m "feat(library): add cheap metadata read to LibraryScanner"
```

---

### Task 7: `LibraryService` — register root, rescan, shallow upsert

**Files:**
- Create: `EchoCore/Services/Library/LibraryService.swift`
- Test: `EchoTests/LibraryServiceTests.swift`

**Interfaces:**
- Consumes: `LibraryRootDAO`, `AudiobookDAO`, `LibraryScanner`, `LibraryAccess`.
- Produces: `@MainActor struct LibraryService { init(db: DatabaseService); func registerRoot(url: URL, now: () -> String) throws -> LibraryRootRecord; func rescan(root: LibraryRootRecord, discover: (URL) -> [DiscoveredBook], now: () -> String) throws -> RescanResult }` where `struct RescanResult: Equatable { var added: Int; var updated: Int; var hidden: Int }`. `rescan` takes the `discover` closure so tests inject a fixed book list (production passes `LibraryScanner.discoverBooks`). Shallow rows get `indexState = 0`, `isAvailable = true`, `sourceRootID = root.id`, `authorSort` set; books previously under the root but absent this scan get `isAvailable = false`. Metadata enrichment (title/author/cover) is applied in Task 8.

- [ ] **Step 1: Write the failing test**

Create `EchoTests/LibraryServiceTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
struct LibraryServiceTests {
    private func fixedNow() -> String { "2026-06-27T00:00:00Z" }

    @Test func rescanInsertsShallowRowsForNewBooks() throws {
        let db = try DatabaseService(inMemory: ())
        let service = LibraryService(db: db)
        let root = try service.registerRoot(
            url: URL(fileURLWithPath: "/Lib", isDirectory: true), now: fixedNow)

        let discovered = [
            DiscoveredBook(
                folderURL: URL(fileURLWithPath: "/Lib/Dune", isDirectory: true),
                audioFiles: [URL(fileURLWithPath: "/Lib/Dune/d.m4b")], companionEPUB: nil)
        ]
        let result = try service.rescan(root: root, discover: { _ in discovered }, now: fixedNow)

        #expect(result.added == 1)
        let book = try AudiobookDAO(db: db.writer).get("file:///Lib/Dune/")
        #expect(book?.indexState == 0)
        #expect(book?.isAvailable == true)
        #expect(book?.sourceRootID == root.id)
    }

    @Test func rescanHidesBooksThatVanished() throws {
        let db = try DatabaseService(inMemory: ())
        let service = LibraryService(db: db)
        let root = try service.registerRoot(
            url: URL(fileURLWithPath: "/Lib", isDirectory: true), now: fixedNow)
        let dune = DiscoveredBook(
            folderURL: URL(fileURLWithPath: "/Lib/Dune", isDirectory: true),
            audioFiles: [URL(fileURLWithPath: "/Lib/Dune/d.m4b")], companionEPUB: nil)

        _ = try service.rescan(root: root, discover: { _ in [dune] }, now: fixedNow)
        let result = try service.rescan(root: root, discover: { _ in [] }, now: fixedNow)

        #expect(result.hidden == 1)
        #expect(try AudiobookDAO(db: db.writer).get("file:///Lib/Dune/")?.isAvailable == false)
    }

    @Test func registerRootPersistsBookmarkAndRow() throws {
        let db = try DatabaseService(inMemory: ())
        let service = LibraryService(db: db)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("lib-reg-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let root = try service.registerRoot(url: tmp, now: fixedNow)
        #expect(try LibraryRootDAO(db: db.writer).get(root.id) != nil)
        #expect(root.bookmark.isEmpty == false)
    }
}
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `make build-tests CODE_SIGNING_ALLOWED=NO && make test-only FILTER=EchoTests/LibraryServiceTests`
Expected: FAIL — "cannot find 'LibraryService'".

- [ ] **Step 3: Create the service**

Create `EchoCore/Services/Library/LibraryService.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import os.log

/// Owns the on-device Library: registers folder roots, rescans them for books
/// (cheap shallow upsert), and resolves a book's URL for opening. A launcher
/// layer above the single-book player — it does not change playback.
@MainActor
struct LibraryService {
    private let logger = Logger(category: "LibraryService")
    private let db: DatabaseService

    init(db: DatabaseService) {
        self.db = db
    }

    struct RescanResult: Equatable {
        var added: Int
        var updated: Int
        var hidden: Int
    }

    /// Registers `url` as a rescannable root: stores its security-scoped bookmark
    /// and a `library_root` row. `now` injects the timestamp for testability.
    @discardableResult
    func registerRoot(url: URL, now: () -> String = { Date().ISO8601Format() }) throws
        -> LibraryRootRecord
    {
        let bookmark = LibraryAccess.makeBookmark(for: url) ?? Data()
        let root = LibraryRootRecord(
            id: "root-\(UUID().uuidString)",
            displayName: url.lastPathComponent,
            bookmark: bookmark,
            addedAt: now(),
            lastScannedAt: nil)
        try LibraryRootDAO(db: db.writer).save(root)
        return root
    }

    /// Rescans a root: shallow-upserts newly found books, refreshes availability
    /// for present ones, and hides ones that vanished (never deleted). `discover`
    /// is injected so tests pass a fixed book list. Metadata enrichment is layered
    /// on in a later task; this pass establishes identity + availability.
    @discardableResult
    func rescan(
        root: LibraryRootRecord,
        discover: (URL) -> [DiscoveredBook] = { LibraryScanner.discoverBooks(in: $0) },
        now: () -> String = { Date().ISO8601Format() }
    ) throws -> RescanResult {
        guard let rootURL = LibraryAccess.resolveURL(from: root.bookmark)?.url
        else {
            logger.warning("Root \(root.id) bookmark unresolved; skipping rescan.")
            return RescanResult(added: 0, updated: 0, hidden: 0)
        }

        let dao = AudiobookDAO(db: db.writer)
        let found = discover(rootURL)
        let foundIDs = Set(found.map { $0.folderURL.absoluteString })
        var result = RescanResult(added: 0, updated: 0, hidden: 0)
        let timestamp = now()

        for book in found {
            let id = book.folderURL.absoluteString
            if let existing = try dao.get(id) {
                var updated = existing
                updated.isAvailable = true
                updated.lastSeenAt = timestamp
                if updated.sourceRootID == nil { updated.sourceRootID = root.id }
                try dao.save(updated)
                result.updated += 1
            } else {
                let record = AudiobookRecord(
                    id: id,
                    title: book.folderURL.lastPathComponent,
                    author: nil,
                    duration: 0,
                    fileCount: book.audioFiles.count,
                    addedAt: timestamp,
                    indexState: 0,
                    isAvailable: true,
                    lastSeenAt: timestamp,
                    authorSort: nil,
                    sourceRootID: root.id)
                try dao.save(record)
                result.added += 1
            }
        }

        // Hide books previously under this root that weren't found this pass.
        let knownUnderRoot = try db.writer.read { db in
            try AudiobookRecord
                .filter(Column("source_root_id") == root.id)
                .filter(Column("is_available") == true)
                .fetchAll(db)
        }
        for book in knownUnderRoot where !foundIDs.contains(book.id) {
            var hidden = book
            hidden.isAvailable = false
            try dao.save(hidden)
            result.hidden += 1
        }

        var stampedRoot = root
        stampedRoot.lastScannedAt = timestamp
        try LibraryRootDAO(db: db.writer).save(stampedRoot)
        return result
    }
}
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `make build-tests CODE_SIGNING_ALLOWED=NO && make test-only FILTER=EchoTests/LibraryServiceTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/Library/LibraryService.swift EchoTests/LibraryServiceTests.swift
git commit -m "feat(library): add LibraryService register-root + rescan"
```

---

### Task 8: `LibraryService` — metadata enrichment + author-sort on rescan

**Files:**
- Modify: `EchoCore/Services/Library/LibraryService.swift`
- Test: `EchoTests/LibraryServiceTests.swift` (add case)

**Interfaces:**
- Produces: an overload `func rescan(root:discover:readMetadata:coversDir:now:) async throws -> RescanResult` where `readMetadata: (DiscoveredBook) async -> LibraryScanner.ScannedMetadata` is injected (tests pass a stub; production passes `LibraryScanner.readMetadata`). New/updated rows get `title`, `author`, `narrator`, `duration`, `authorSort`, and `coverArtPath` (cover bytes written under `coversDir`).

- [ ] **Step 1: Write the failing test**

Add to `EchoTests/LibraryServiceTests.swift`:

```swift
    @Test func rescanAppliesInjectedMetadata() async throws {
        let db = try DatabaseService(inMemory: ())
        let service = LibraryService(db: db)
        let root = try service.registerRoot(
            url: URL(fileURLWithPath: "/Lib", isDirectory: true), now: fixedNow)
        let dune = DiscoveredBook(
            folderURL: URL(fileURLWithPath: "/Lib/Dune", isDirectory: true),
            audioFiles: [URL(fileURLWithPath: "/Lib/Dune/d.m4b")], companionEPUB: nil)
        let covers = FileManager.default.temporaryDirectory
            .appendingPathComponent("covers-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: covers) }

        _ = try await service.rescan(
            root: root,
            discover: { _ in [dune] },
            readMetadata: { _ in
                LibraryScanner.ScannedMetadata(
                    title: "Dune", author: "Tolkien, J.R.R.", narrator: "Scott Brick",
                    duration: 4242, coverImageData: Data([0xFF, 0xD8]))
            },
            coversDir: covers,
            now: fixedNow)

        let book = try AudiobookDAO(db: db.writer).get("file:///Lib/Dune/")
        #expect(book?.title == "Dune")
        #expect(book?.author == "Tolkien, J.R.R.")
        #expect(book?.narrator == "Scott Brick")
        #expect(book?.duration == 4242)
        #expect(book?.authorSort == "j.r.r. tolkien")
        #expect(book?.coverArtPath != nil)
    }
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `make build-tests CODE_SIGNING_ALLOWED=NO && make test-only FILTER=EchoTests/LibraryServiceTests`
Expected: FAIL — no `rescan(...readMetadata:coversDir:...)` overload.

- [ ] **Step 3: Add the async enrichment overload**

Add to `LibraryService` in `EchoCore/Services/Library/LibraryService.swift`:

```swift
    /// Rescan that also enriches each found book with cheap metadata (title,
    /// author, narrator, duration, cover). `readMetadata` is injected for tests;
    /// production passes `LibraryScanner.readMetadata`. Covers are written as JPEG
    /// under `coversDir` and the relative path stored on the row.
    @discardableResult
    func rescan(
        root: LibraryRootRecord,
        discover: (URL) -> [DiscoveredBook] = { LibraryScanner.discoverBooks(in: $0) },
        readMetadata: (DiscoveredBook) async -> LibraryScanner.ScannedMetadata,
        coversDir: URL,
        now: () -> String = { Date().ISO8601Format() }
    ) async throws -> RescanResult {
        guard let rootURL = LibraryAccess.resolveURL(from: root.bookmark)?.url else {
            return RescanResult(added: 0, updated: 0, hidden: 0)
        }
        try FileManager.default.createDirectory(
            at: coversDir, withIntermediateDirectories: true)

        let dao = AudiobookDAO(db: db.writer)
        let found = discover(rootURL)
        let foundIDs = Set(found.map { $0.folderURL.absoluteString })
        var result = RescanResult(added: 0, updated: 0, hidden: 0)
        let timestamp = now()

        for book in found {
            let id = book.folderURL.absoluteString
            let meta = await readMetadata(book)
            let coverPath = writeCover(meta.coverImageData, id: id, coversDir: coversDir)
            let existing = try dao.get(id)
            var record = existing ?? AudiobookRecord(
                id: id, title: meta.title, author: meta.author, duration: meta.duration,
                fileCount: book.audioFiles.count, addedAt: timestamp)
            record.title = meta.title
            record.author = meta.author
            record.narrator = meta.narrator
            record.duration = meta.duration
            record.authorSort = LibraryAccess.authorSort(meta.author)
            record.coverArtPath = coverPath ?? record.coverArtPath
            record.fileCount = book.audioFiles.count
            record.isAvailable = true
            record.lastSeenAt = timestamp
            record.indexState = existing?.indexState ?? 0
            if record.sourceRootID == nil { record.sourceRootID = root.id }
            try dao.save(record)
            if existing == nil { result.added += 1 } else { result.updated += 1 }
        }

        let knownUnderRoot = try db.writer.read { db in
            try AudiobookRecord
                .filter(Column("source_root_id") == root.id)
                .filter(Column("is_available") == true)
                .fetchAll(db)
        }
        for book in knownUnderRoot where !foundIDs.contains(book.id) {
            var hidden = book
            hidden.isAvailable = false
            try dao.save(hidden)
            result.hidden += 1
        }

        var stampedRoot = root
        stampedRoot.lastScannedAt = timestamp
        try LibraryRootDAO(db: db.writer).save(stampedRoot)
        return result
    }

    private func writeCover(_ data: Data?, id: String, coversDir: URL) -> String? {
        guard let data else { return nil }
        let name = "\(stableHash(id)).jpg"
        let url = coversDir.appendingPathComponent(name)
        do {
            try data.write(to: url)
            return name
        } catch {
            logger.error("Cover write failed for \(id): \(error.localizedDescription)")
            return nil
        }
    }

    private func stableHash(_ s: String) -> String {
        var hasher = Hasher()
        hasher.combine(s)
        return String(UInt(bitPattern: hasher.finalize()), radix: 16)
    }
```

> Note: `Hasher` is per-run seeded, which is fine here — the cover filename is recomputed from `id` within the same process during a rescan and the row stores the resulting relative path. If you need a cross-launch-stable filename, swap `stableHash` for a SHA-256 of `id` (CryptoKit, already imported in `LibraryScanner`).

- [ ] **Step 4: Run the test, verify it passes**

Run: `make build-tests CODE_SIGNING_ALLOWED=NO && make test-only FILTER=EchoTests/LibraryServiceTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/Library/LibraryService.swift EchoTests/LibraryServiceTests.swift
git commit -m "feat(library): enrich rescanned books with metadata + cover"
```

---

### Task 9: `LibraryService` — list, group by axis, and `urlForOpening`

**Files:**
- Modify: `EchoCore/Services/Library/LibraryService.swift`
- Test: `EchoTests/LibraryServiceTests.swift` (add cases)

**Interfaces:**
- Produces: `enum LibraryAxis { case recentlyAdded, author, topic, folder }` (status axes added in Task 10); `struct LibrarySection: Equatable { let title: String; let books: [AudiobookRecord] }`; `func books(includeUnavailable: Bool) throws -> [AudiobookRecord]`; `func sections(by axis: LibraryAxis, includeUnavailable: Bool) throws -> [LibrarySection]`; `func urlForOpening(_ book: AudiobookRecord) throws -> URL` (resolves the book's root bookmark and returns the book folder URL).

- [ ] **Step 1: Write the failing test**

Add to `EchoTests/LibraryServiceTests.swift`:

```swift
    @Test func booksHidesUnavailableByDefault() throws {
        let db = try DatabaseService(inMemory: ())
        let dao = AudiobookDAO(db: db.writer)
        try dao.save(AudiobookRecord(
            id: "a", title: "A", author: nil, duration: 0, fileCount: nil,
            addedAt: "2026-06-27T00:00:00Z", isAvailable: true))
        try dao.save(AudiobookRecord(
            id: "b", title: "B", author: nil, duration: 0, fileCount: nil,
            addedAt: "2026-06-26T00:00:00Z", isAvailable: false))

        let service = LibraryService(db: db)
        #expect(try service.books(includeUnavailable: false).map(\.id) == ["a"])
        #expect(try service.books(includeUnavailable: true).map(\.id).sorted() == ["a", "b"])
    }

    @Test func sectionsByAuthorGroupOnNormalizedKey() throws {
        let db = try DatabaseService(inMemory: ())
        let dao = AudiobookDAO(db: db.writer)
        try dao.save(AudiobookRecord(
            id: "1", title: "X", author: "Tolkien, J.R.R.", duration: 0, fileCount: nil,
            addedAt: "2026-06-27T00:00:00Z", isAvailable: true, authorSort: "j.r.r. tolkien"))
        try dao.save(AudiobookRecord(
            id: "2", title: "Y", author: "J.R.R. Tolkien", duration: 0, fileCount: nil,
            addedAt: "2026-06-26T00:00:00Z", isAvailable: true, authorSort: "j.r.r. tolkien"))

        let service = LibraryService(db: db)
        let sections = try service.sections(by: .author, includeUnavailable: false)
        #expect(sections.count == 1)
        #expect(sections.first?.books.count == 2)
    }
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `make build-tests CODE_SIGNING_ALLOWED=NO && make test-only FILTER=EchoTests/LibraryServiceTests`
Expected: FAIL — no `books`/`sections` members.

- [ ] **Step 3: Add list + grouping + open-URL**

Add to `LibraryService`:

```swift
    enum LibraryAxis { case recentlyAdded, author, topic, folder }

    struct LibrarySection: Equatable {
        let title: String
        let books: [AudiobookRecord]
    }

    func books(includeUnavailable: Bool) throws -> [AudiobookRecord] {
        try db.writer.read { db in
            var request = AudiobookRecord.order(Column("added_at").desc)
            if !includeUnavailable {
                request = request.filter(Column("is_available") == true)
            }
            return try request.fetchAll(db)
        }
    }

    func sections(by axis: LibraryAxis, includeUnavailable: Bool) throws -> [LibrarySection] {
        let all = try books(includeUnavailable: includeUnavailable)
        switch axis {
        case .recentlyAdded:
            return [LibrarySection(title: "Recently Added", books: all)]
        case .author:
            return grouped(all, key: { $0.authorSort ?? "unknown" },
                title: { $0.author ?? "Unknown Author" })
        case .topic:
            return groupedByTopic(all)
        case .folder:
            return grouped(all, key: { rootKey(for: $0) }, title: { rootKey(for: $0) })
        }
    }

    /// Resolves the folder URL to open this book, re-acquiring access through its
    /// library root's bookmark. Callers then pass the URL to `PlayerModel.loadFolder`.
    func urlForOpening(_ book: AudiobookRecord) throws -> URL {
        if let rootID = book.sourceRootID,
            let root = try LibraryRootDAO(db: db.writer).get(rootID),
            let resolved = LibraryAccess.resolveURL(from: root.bookmark) {
            _ = resolved.url.startAccessingSecurityScopedResource()
            return URL(fileURLWithPath: book.id.replacingOccurrences(of: "file://", with: ""))
                .standardizedFileURL
        }
        guard let url = URL(string: book.id) else {
            throw LibraryError.unresolvableBook(book.id)
        }
        return url
    }

    enum LibraryError: Error { case unresolvableBook(String) }

    private func grouped(
        _ books: [AudiobookRecord], key: (AudiobookRecord) -> String,
        title: (AudiobookRecord) -> String
    ) -> [LibrarySection] {
        let groups = Dictionary(grouping: books, by: key)
        return groups.keys.sorted().map { k in
            let items = groups[k]!.sorted { $0.title < $1.title }
            return LibrarySection(title: title(items[0]), books: items)
        }
    }

    private func groupedByTopic(_ books: [AudiobookRecord]) -> [LibrarySection] {
        var byTopic: [String: [AudiobookRecord]] = [:]
        for book in books {
            for topic in decodeTopics(book.topicsJSON) {
                byTopic[topic, default: []].append(book)
            }
        }
        return byTopic.keys.sorted().map { topic in
            LibrarySection(title: topic, books: byTopic[topic]!.sorted { $0.title < $1.title })
        }
    }

    private func decodeTopics(_ json: String?) -> [String] {
        guard let json, let data = json.data(using: .utf8),
            let topics = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return topics
    }

    private func rootKey(for book: AudiobookRecord) -> String {
        URL(string: book.id)?.deletingLastPathComponent().lastPathComponent ?? "Other"
    }
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `make build-tests CODE_SIGNING_ALLOWED=NO && make test-only FILTER=EchoTests/LibraryServiceTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/Library/LibraryService.swift EchoTests/LibraryServiceTests.swift
git commit -m "feat(library): list + group-by-axis + open-URL resolution"
```

---

### Task 10: `LibraryService` — derived study & processing status

**Files:**
- Modify: `EchoCore/Services/Library/LibraryService.swift`
- Test: `EchoTests/LibraryServiceTests.swift` (add cases)

**Interfaces:**
- Produces: `enum StudyStatus { case notStarted, inProgress, finished }`; `struct ProcessingStatus: OptionSet { let rawValue: Int; static let aligned, narrated, transcribed }`; `func studyStatus(for book: AudiobookRecord) throws -> StudyStatus`; `func processingStatus(for book: AudiobookRecord) throws -> ProcessingStatus`. Plus `LibraryAxis` gains `.studyStatus` and `.processingStatus` cases handled in `sections(by:includeUnavailable:)`.

**⚠️ Execution-time confirms (do these first, then write the queries verbatim):**
- `playback_event` columns for progress (Schema_V1:136) — confirm the `audiobook_id` column and a progress/position column; "finished" = max progress ≥ 0.99 of duration, "in progress" = any event with progress > 0, else "not started".
- `track` table name + `audiobook_id` + `narration_voice` columns (`TrackRecord`) — "narrated" = ≥1 track with non-null `narration_voice`.
- `transcription_segment` (`TranscriptionRecord`) + its `audiobook_id` column — "transcribed" = ≥1 row.
- "aligned" = `AlignmentAnchorDAO(db:).anchors(for: book.id).count > 2` (the import finalizer seeds a trivial first/last pair; >2 means real anchors). Confirm the seed count before locking the threshold.

- [ ] **Step 1: Write the failing test** (seed via raw SQL so it's independent of DAO specifics)

```swift
    @Test func processingStatusReflectsNarrationAndTranscription() throws {
        let db = try DatabaseService(inMemory: ())
        try db.writer.write { db in
            try db.execute(sql: """
                INSERT INTO audiobook (id, title, duration) VALUES ('bk', 'T', 100)
                """)
            try db.execute(sql: """
                INSERT INTO track (id, audiobook_id, title, duration, file_path, sort_order, narration_voice)
                VALUES ('t1', 'bk', 'c1', 50, '/bk/c1.wav', 0, 'af_heart')
                """)
        }
        let service = LibraryService(db: db)
        let book = try #require(try AudiobookDAO(db: db.writer).get("bk"))
        #expect(try service.processingStatus(for: book).contains(.narrated))
        #expect(!(try service.processingStatus(for: book).contains(.transcribed)))
    }

    @Test func studyStatusNotStartedWithNoPlayback() throws {
        let db = try DatabaseService(inMemory: ())
        try db.writer.write { db in
            try db.execute(sql: "INSERT INTO audiobook (id, title, duration) VALUES ('bk','T',100)")
        }
        let service = LibraryService(db: db)
        let book = try #require(try AudiobookDAO(db: db.writer).get("bk"))
        #expect(try service.studyStatus(for: book) == .notStarted)
    }
```

> If the confirmed `track` schema differs (e.g. a required column), adjust the seed INSERT to satisfy NOT NULL constraints — keep the assertions.

- [ ] **Step 2: Run the test, verify it fails**

Run: `make build-tests CODE_SIGNING_ALLOWED=NO && make test-only FILTER=EchoTests/LibraryServiceTests`
Expected: FAIL — no `processingStatus`/`studyStatus`.

- [ ] **Step 3: Implement derived status** (write the verbatim queries against the confirmed columns)

Add to `LibraryService` — `ProcessingStatus` OptionSet, the two derive methods (raw-SQL counts for narrated/transcribed/playback, `AlignmentAnchorDAO` for aligned), and extend `sections(by:)` with `.studyStatus`/`.processingStatus` cases that bucket books into fixed-order sections ("In Progress", "Finished", "Not Started"; "Aligned", "Narrated", "Transcribed", "Not Processed"). (Full code authored at execution time once the four schema confirms above are pinned — each is a `try db.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) …") }` ≥ 1 check plus the anchor threshold.)

- [ ] **Step 4: Run the test, verify it passes**

Run: `make build-tests CODE_SIGNING_ALLOWED=NO && make test-only FILTER=EchoTests/LibraryServiceTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/Library/LibraryService.swift EchoTests/LibraryServiceTests.swift
git commit -m "feat(library): derive study + processing status"
```

---

## Milestones 3–4 — Roadmap (expand into a follow-up plan after M1–M2 land)

These touch custom UI (`UnifiedBottomDock`, `BottomToolbarView`, new SwiftUI views) that isn't unit-tested (UI tests are excluded from the scheme), so they verify via build + simulator/preview rather than failing-test-first. Expand each into TDD-where-possible tasks after reading the dock + existing cover/card components.

**Milestone 3 — Library tab, smart-landing, opening a book**
- **T11 — `TabSelection.library`:** add the case + `icon`/`label` in `Shared/TabSelection.swift`.
- **T12 — Dock affordance:** add a Library destination to `EchoCore/Views/Components/UnifiedBottomDock.swift` / `EchoCore/Views/BottomToolbarView.swift` (today a 2-way Read/Now-Playing chip — confirm the intended 3-way affordance with the owner).
- **T13 — `LibraryViewModel`** (`@MainActor @Observable final class`, `@ObservationIgnored let db`, holds selected axis / `includeUnavailable` / sections / rescan progress; calls `LibraryService`). Unit-test the non-UI logic (axis selection → `sections` mapping) against `DatabaseService(inMemory:)`.
- **T14 — `LibraryView`** (facet-chip cover grid + "Browse by…" drill-down lists; processing-status dot; reuse existing cover/artwork components). Verify on simulator.
- **T15 — `RootTabView` integration:** add `case .library: LibraryView(...)` to the body switch; add smart-landing in `.onAppear` *after* `restoreLastSelectionIfPossible()` — `if model.folderURL == nil { model.selectedTab = .library }` (must not override a deep-link-set tab, see `handleDeepLink`).
- **T16 — Open a book:** tapping a shelf item calls `LibraryService.urlForOpening` then `model.loadFolder(url:)`; first open runs the existing import path and flips `index_state = 1` (wire the flip in `PlayerLoadingCoordinator`/post-load).

**Milestone 4 — Roots, rescan & missing-file UI**
- **T17 — Add Folder:** reuse `FolderPicker`; on pick call `LibraryService.registerRoot` + kick a rescan `Task`.
- **T18 — Auto-register navigated folders:** in the existing `FolderPicker`→`loadFolder` path, also `registerRoot` (dedupe by resolved path) so every opened folder becomes rescannable (Component D).
- **T19 — Rescan UI:** per-root + "Rescan all" buttons with bounded-concurrency progress (cap parallel `AVAsset` reads).
- **T20 — Manage Roots screen:** list roots + `last_scanned_at`; Remove root (forget books / keep via minting per-book bookmarks from the live root grant before release).
- **T21 — Missing-file UI:** hide unavailable by default; "Show unavailable" toggle; Relocate (re-pick) / Remove.

**Docs (before the M1–M2 PR, per project rule):** run the **doc-sync** skill — add a Library subsystem section to `ARCHITECTURE.md`, note the V27 schema, and update `README.md`/`ROADMAP.md`/`CHANGELOG`. Run **schema-migration-reviewer** on Task 1 and **cross-platform-parity-reviewer** when macOS adopts the core.

---

## Self-Review

- **Spec coverage:** browse axes → Tasks 9–10 + roadmap T14; rescan cheap-read/defer → Tasks 6–8 + T16; per-root access → Tasks 3–4, 7, 9; hide-unavailable → Tasks 7, 9 + T21; smart-landing → T15; roots + auto-register (Component D) → Tasks 3,7 + T17–T18; V27 migration → Task 1. ✅ All spec sections map to a task.
- **Placeholders:** Task 10 Step 3 and Milestones 3–4 are deliberately roadmap-level (gated on execution-time schema/UI confirms that can't be guessed without inventing signatures) — every *fully-specified* task (1–9) carries complete code. This is an intentional milestone split, not a hidden TODO.
- **Type consistency:** `AudiobookRecord` field names, `LibraryRootRecord`/`LibraryRootDAO`, `DiscoveredBook`, `ScannedMetadata`, `RescanResult`, `LibrarySection`, `LibraryAxis` are used identically across Tasks 1–10.
