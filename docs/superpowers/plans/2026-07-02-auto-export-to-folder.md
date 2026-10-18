# Auto-Export Study Captures to Folder — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When enabled, Echo continuously mirrors each book's study captures (notes, bookmarks, flashcards) as deterministic Markdown files into a user-picked folder (typically iCloud Drive), so external tooling can ingest them on the Mac.

**Architecture:** A new `@MainActor @Observable AutoExportService` observes the `note`/`bookmark`/`flashcard` GRDB tables via `DatabaseRegionObservation`, debounces 5 s, and rewrites per-book mirror files inside an Echo-owned `Echo Study Notes/` subfolder of the destination. Rendering is a pure `AutoExportMarkdown` enum (deterministic output + SHA-256 skip-if-unchanged); persistence is a Schema V34 pair of tables (destination bookmark + per-book dirty/outbox state) behind `StudyAutoExportDAO`. The existing manual export (`StudyNotesExportService`) is untouched except for additive, defaulted fields.

**Tech Stack:** SwiftUI, Swift Testing, GRDB (`DatabaseRegionObservation`), CryptoKit (SHA-256), `LibraryAccess` security-scoped bookmarks, `@MainActor @Observable` services, existing Echo make targets.

**Design spec:** `docs/superpowers/specs/2026-07-02-auto-export-to-folder-design.md` — read it first; every decision below is justified there.

## Global Constraints

- Branch base: `origin/nightly` @ `24610794`. Feature PRs target `nightly` (`gh pr create --base nightly …`); never push `main`/`weekly`/`nightly` directly.
- **Migration number contention:** this plan claims `v34_study_auto_export`. Before Task 1, re-confirm `v34_*` is still free in `Shared/Database/DatabaseService.swift` (`runMigrations`); if taken, renumber everywhere (file, registration, test suite name) and say so in the PR body.
- Swift 6 language mode with MainActor default isolation; do not raise deployment targets or Swift version.
- Concrete types + constructor/closure injection only. **No protocols, no mocks** — test seams are `DatabaseService(inMemory:)` and temp directories (CODE_AUDIT §10.1 rule).
- No third-party frameworks (CryptoKit and UniformTypeIdentifiers are system frameworks).
- Every new Swift file starts with `// SPDX-License-Identifier: GPL-3.0-or-later` (public GPL-3.0 repo).
- Swift Testing only; UI tests stay excluded from the scheme's test action.
- 16 GB build machine: run every build/test through the gate — `"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make …` — never two `xcodebuild` invocations concurrently, never uncapped parallel testing.
- The manual export path (`StudyNotesExportService` output for existing callers, `StudyNotesExportView`, `AllStudyNotesExportView`) must not change behavior.
- Bookmark location fields (`latitude`/`longitude`/`placeName`) are **never** exported (spec privacy rule). The exporter **never reads** destination files — whole-file atomic rewrites only.
- macOS Settings surface is **out of scope** (spec Non-Goal #7); the engine must still compile for all targets that build `EchoCore`/`Shared` sources.
- The Pro gate (Task 7) is implemented as specced but is flagged for ratification: the PR body must call out "Entitlement change: auto-export is Pro-gated — Dan ratifies" prominently.

---

## File Structure

- Create `Shared/Database/Migrations/Schema_V34.swift`
  - `study_export_destination` (bookmark BLOB, single `'default'` row) + `study_export_state` (per-book dirty/outbox) tables.
- Modify `Shared/Database/DatabaseService.swift`
  - Register `v34_study_auto_export`.
- Create `Shared/Database/DAOs/StudyAutoExportDAO.swift`
  - Records + DAO for both V34 tables (the `LibraryRootDAO` idiom).
- Modify `EchoCore/Services/StudyNotesExportService.swift`
  - Additive, defaulted `id`/`author` fields on the existing DTO structs.
- Modify `EchoCore/Services/StudyNotesExportDatabaseSource.swift`
  - Populate the new fields from records it already reads.
- Create `EchoCore/Services/AutoExportMarkdown.swift`
  - Pure deterministic renderer: frontmatter, capture-ID markers, chapter attribution, file naming, SHA-256.
- Create `EchoCore/Services/AutoExportService.swift`
  - `@MainActor @Observable` engine: capture observation, debounce, export pass, destination handling, status for Settings.
- Modify `EchoCore/Services/SettingsManager.swift`
  - `studyAutoExportEnabled` default + key + persisted property.
- Create `EchoCore/Views/AutoExportSettingsRows.swift`
  - Pro-gated toggle, folder picker (`fileImporter`, `.folder`), passive status footer.
- Modify `EchoCore/Views/SettingsView.swift`
  - Mount `AutoExportSettingsRows()` directly after the `Section("Study & Notes")` block.
- Modify `EchoCore/EchoCoreApp.swift`
  - Construct + start the service; inject via `.environment`.
- Modify `EchoCore/Views/RootTabView.swift`
  - Session-end flush in the existing `scenePhase` background branch.
- Modify `ARCHITECTURE.md`, `CHANGELOG.md`, `docs/guides/user-manual.md`
  - Feature documentation (Task 9).
- Create `EchoTests/SchemaV34Tests.swift`, `EchoTests/StudyAutoExportDAOTests.swift`, `EchoTests/AutoExportMarkdownTests.swift`, `EchoTests/AutoExportServiceTests.swift`
- Modify `EchoTests/StudyNotesExportServiceTests.swift` (source DTO additions), `EchoTests/EchoCoreTests.swift` (settings default), `EchoTests/SettingsExtractionTests.swift` (structural guardrails)

---

### Task 1: Schema V34 — Destination + Export State Tables

**Files:**
- Create: `Shared/Database/Migrations/Schema_V34.swift`
- Modify: `Shared/Database/DatabaseService.swift` (the `runMigrations` block, after `v33_study_plan_card_pacing`)
- Create: `EchoTests/SchemaV34Tests.swift`

**Interfaces:**
- Consumes: `DatabaseService(inMemory:)`, GRDB `DatabaseMigrator`.
- Produces: tables `study_export_destination(id TEXT PK CHECK 'default', bookmark BLOB NOT NULL, display_path TEXT NOT NULL, needs_repick BOOL NOT NULL DEFAULT 0, added_at TEXT NOT NULL)` and `study_export_state(book_id TEXT PK, file_name TEXT, dirty BOOL NOT NULL DEFAULT 1, content_sha256 TEXT, last_exported_at TEXT, last_error TEXT)`.

- [ ] **Step 0: Re-confirm the migration number**

Run:

```bash
grep -n "registerMigration" Shared/Database/DatabaseService.swift | tail -3
```

Expected: the last registered migration is `v33_study_plan_card_pacing`. If a `v34_*` already exists, renumber this feature's migration to the next free version everywhere it appears in this plan.

- [ ] **Step 1: Write the failing tests**

Create `EchoTests/SchemaV34Tests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

struct SchemaV34Tests {
    @Test func migrationCreatesAutoExportTables() throws {
        let db = try DatabaseService(inMemory: ())
        try db.writer.read { db in
            #expect(try db.tableExists("study_export_destination"))
            #expect(try db.tableExists("study_export_state"))
            #expect(try db.columns(in: "study_export_destination").map(\.name).contains("bookmark"))
            #expect(try db.columns(in: "study_export_state").map(\.name).contains("dirty"))
        }
    }

    @Test func destinationTableAllowsOnlyTheDefaultRow() throws {
        let db = try DatabaseService(inMemory: ())
        try db.writer.write { db in
            try db.execute(
                sql: """
                    INSERT INTO study_export_destination (id, bookmark, display_path, added_at)
                    VALUES ('default', x'00', '/x', '2026-07-02T00:00:00Z')
                    """)
        }
        #expect(throws: (any Error).self) {
            try db.writer.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO study_export_destination (id, bookmark, display_path, added_at)
                        VALUES ('second', x'00', '/y', '2026-07-02T00:00:00Z')
                        """)
            }
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test-only FILTER=EchoTests/SchemaV34Tests
```

Expected: both tests fail — the tables do not exist.

- [ ] **Step 3: Create the migration and register it**

Create `Shared/Database/Migrations/Schema_V34.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

/// V34 — Study auto-export: the picked destination folder (security-scoped
/// bookmark, following the `library_root.bookmark` precedent) plus per-book
/// export state whose persisted `dirty` flags are the retry outbox.
///
/// Additive only: two new tables; no changes to existing tables or shipped
/// migrations.
enum Schema_V34 {
    nonisolated static func migrate(_ db: Database) throws {
        try db.create(table: "study_export_destination", ifNotExists: true) { t in
            // Single-row table: the CHECK models "one destination" honestly
            // while leaving room for multi-destination later.
            t.column("id", .text).primaryKey().check { $0 == "default" }
            t.column("bookmark", .blob).notNull()
            t.column("display_path", .text).notNull()
            t.column("needs_repick", .boolean).notNull().defaults(to: false)
            t.column("added_at", .text).notNull()
        }

        try db.create(table: "study_export_state", ifNotExists: true) { t in
            t.column("book_id", .text).primaryKey()
            t.column("file_name", .text)
            t.column("dirty", .boolean).notNull().defaults(to: true)
            t.column("content_sha256", .text)
            t.column("last_exported_at", .text)
            t.column("last_error", .text)
        }

        try db.create(
            index: "idx_study_export_state_dirty",
            on: "study_export_state", columns: ["dirty"], ifNotExists: true)
    }
}
```

In `Shared/Database/DatabaseService.swift`, immediately after the `v33_study_plan_card_pacing` registration, add:

```swift
        migrator.registerMigration("v34_study_auto_export") { db in
            try Schema_V34.migrate(db)
        }
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test-only FILTER=EchoTests/SchemaV34Tests
```

Expected: both pass.

- [ ] **Step 5: Commit**

```bash
git add Shared/Database/Migrations/Schema_V34.swift Shared/Database/DatabaseService.swift EchoTests/SchemaV34Tests.swift
git commit -m "feat(db): add v34 study auto-export tables"
```

---

### Task 2: StudyAutoExportDAO

**Files:**
- Create: `Shared/Database/DAOs/StudyAutoExportDAO.swift`
- Create: `EchoTests/StudyAutoExportDAOTests.swift`

**Interfaces:**
- Consumes: Schema V34 tables, `DatabaseWriter`.
- Produces (used by Tasks 5–7):
  - `StudyExportDestinationRecord { id, bookmark: Data, displayPath: String, needsRepick: Bool, addedAt: String }`
  - `StudyExportStateRecord { bookId: String, fileName: String?, dirty: Bool, contentSha256: String?, lastExportedAt: String?, lastError: String? }`
  - `StudyAutoExportDAO(db: DatabaseWriter)` with `destination()`, `saveDestination(bookmark:displayPath:)`, `clearDestination()`, `setNeedsRepick(_:)`, `markDirty(bookIDs:)`, `dirtyStates()`, `state(for:)`, `recordSuccess(bookID:fileName:contentSha256:at:)`, `recordFailure(bookID:error:)`, `removeState(bookID:)`.

- [ ] **Step 1: Write the failing tests**

Create `EchoTests/StudyAutoExportDAOTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct StudyAutoExportDAOTests {
    @Test func destinationRoundTripsAndClears() throws {
        let db = try DatabaseService(inMemory: ())
        let dao = StudyAutoExportDAO(db: db.writer)

        #expect(try dao.destination() == nil)

        try dao.saveDestination(bookmark: Data([0x01, 0x02]), displayPath: "/Users/sample/MacroMark")
        let saved = try #require(try dao.destination())
        #expect(saved.bookmark == Data([0x01, 0x02]))
        #expect(saved.displayPath == "/Users/sample/MacroMark")
        #expect(saved.needsRepick == false)

        try dao.setNeedsRepick(true)
        #expect(try #require(try dao.destination()).needsRepick == true)

        // Re-picking overwrites the single row and resets needsRepick.
        try dao.saveDestination(bookmark: Data([0x03]), displayPath: "/Users/sample/Inbox")
        let replaced = try #require(try dao.destination())
        #expect(replaced.bookmark == Data([0x03]))
        #expect(replaced.needsRepick == false)

        try dao.clearDestination()
        #expect(try dao.destination() == nil)
    }

    @Test func dirtyLifecycleSurvivesSuccessAndFailure() throws {
        let db = try DatabaseService(inMemory: ())
        let dao = StudyAutoExportDAO(db: db.writer)

        try dao.markDirty(bookIDs: ["book-a", "book-b"])
        #expect(try dao.dirtyStates().map(\.bookId) == ["book-a", "book-b"])

        try dao.recordSuccess(
            bookID: "book-a", fileName: "A-12345678.md",
            contentSha256: "abc", at: "2026-07-02T12:00:00Z")
        #expect(try dao.dirtyStates().map(\.bookId) == ["book-b"])
        let stateA = try #require(try dao.state(for: "book-a"))
        #expect(stateA.dirty == false)
        #expect(stateA.fileName == "A-12345678.md")
        #expect(stateA.contentSha256 == "abc")
        #expect(stateA.lastError == nil)

        try dao.recordFailure(bookID: "book-b", error: "disk full")
        let stateB = try #require(try dao.state(for: "book-b"))
        #expect(stateB.dirty == true)
        #expect(stateB.lastError == "disk full")

        // Re-dirtying an exported book keeps its file bookkeeping.
        try dao.markDirty(bookIDs: ["book-a"])
        let redirty = try #require(try dao.state(for: "book-a"))
        #expect(redirty.dirty == true)
        #expect(redirty.fileName == "A-12345678.md")

        try dao.removeState(bookID: "book-a")
        #expect(try dao.state(for: "book-a") == nil)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
```

Expected: compile failure — `StudyAutoExportDAO` does not exist.

- [ ] **Step 3: Create the records and DAO**

Create `Shared/Database/DAOs/StudyAutoExportDAO.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

/// The single user-picked auto-export destination. Stores the security-scoped
/// bookmark (the `library_root.bookmark` precedent) so the folder can be
/// reopened across launches.
struct StudyExportDestinationRecord: Codable, Equatable, FetchableRecord, MutablePersistableRecord {
    var id: String
    var bookmark: Data
    var displayPath: String
    var needsRepick: Bool
    var addedAt: String

    static let databaseTableName = "study_export_destination"
    static let defaultID = "default"

    enum CodingKeys: String, CodingKey {
        case id, bookmark
        case displayPath = "display_path"
        case needsRepick = "needs_repick"
        case addedAt = "added_at"
    }
}

/// Per-book export state. Persisted `dirty` flags are the outbox: set on
/// capture changes, cleared on successful export, kept (with `lastError`) on
/// failure — the database stays the source of truth, so nothing is ever lost.
struct StudyExportStateRecord: Codable, Equatable, FetchableRecord, MutablePersistableRecord {
    var bookId: String
    var fileName: String?
    var dirty: Bool
    var contentSha256: String?
    var lastExportedAt: String?
    var lastError: String?

    static let databaseTableName = "study_export_state"

    enum CodingKeys: String, CodingKey {
        case bookId = "book_id"
        case fileName = "file_name"
        case dirty
        case contentSha256 = "content_sha256"
        case lastExportedAt = "last_exported_at"
        case lastError = "last_error"
    }
}

struct StudyAutoExportDAO {
    private let db: DatabaseWriter

    init(db: DatabaseWriter) {
        self.db = db
    }

    // MARK: Destination

    func destination() throws -> StudyExportDestinationRecord? {
        try db.read { db in
            try StudyExportDestinationRecord.fetchOne(
                db, key: StudyExportDestinationRecord.defaultID)
        }
    }

    func saveDestination(bookmark: Data, displayPath: String) throws {
        var record = StudyExportDestinationRecord(
            id: StudyExportDestinationRecord.defaultID,
            bookmark: bookmark,
            displayPath: displayPath,
            needsRepick: false,
            addedAt: Date.now.ISO8601Format()
        )
        try db.write { db in try record.save(db) }
    }

    func clearDestination() throws {
        _ = try db.write { db in
            try StudyExportDestinationRecord.deleteOne(
                db, key: StudyExportDestinationRecord.defaultID)
        }
    }

    func setNeedsRepick(_ needsRepick: Bool) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE study_export_destination SET needs_repick = ? WHERE id = ?",
                arguments: [needsRepick, StudyExportDestinationRecord.defaultID])
        }
    }

    // MARK: Per-book state

    func markDirty(bookIDs: [String]) throws {
        guard !bookIDs.isEmpty else { return }
        try db.write { db in
            for bookID in bookIDs {
                if var existing = try StudyExportStateRecord.fetchOne(db, key: bookID) {
                    existing.dirty = true
                    try existing.save(db)
                } else {
                    var fresh = StudyExportStateRecord(
                        bookId: bookID, fileName: nil, dirty: true,
                        contentSha256: nil, lastExportedAt: nil, lastError: nil)
                    try fresh.save(db)
                }
            }
        }
    }

    func dirtyStates() throws -> [StudyExportStateRecord] {
        try db.read { db in
            try StudyExportStateRecord
                .filter(Column("dirty") == true)
                .order(Column("book_id"))
                .fetchAll(db)
        }
    }

    func state(for bookID: String) throws -> StudyExportStateRecord? {
        try db.read { db in try StudyExportStateRecord.fetchOne(db, key: bookID) }
    }

    func recordSuccess(bookID: String, fileName: String, contentSha256: String, at date: String) throws {
        var record = StudyExportStateRecord(
            bookId: bookID, fileName: fileName, dirty: false,
            contentSha256: contentSha256, lastExportedAt: date, lastError: nil)
        try db.write { db in try record.save(db) }
    }

    func recordFailure(bookID: String, error: String) throws {
        try db.write { db in
            try db.execute(
                sql: "UPDATE study_export_state SET dirty = 1, last_error = ? WHERE book_id = ?",
                arguments: [error, bookID])
        }
    }

    func removeState(bookID: String) throws {
        _ = try db.write { db in
            try StudyExportStateRecord.deleteOne(db, key: bookID)
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test-only FILTER=EchoTests/StudyAutoExportDAOTests
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Shared/Database/DAOs/StudyAutoExportDAO.swift EchoTests/StudyAutoExportDAOTests.swift
git commit -m "feat(db): study auto-export destination and outbox DAO"
```

---

### Task 3: Capture IDs + Author on the Existing Export DTOs

**Files:**
- Modify: `EchoCore/Services/StudyNotesExportService.swift:8-34` (the `Book`, `Note`, `Card` structs)
- Modify: `EchoCore/Services/StudyNotesExportDatabaseSource.swift` (`books()`, `notes(for:)`, `cards(for:)`)
- Modify: `EchoTests/StudyNotesExportServiceTests.swift` (append the new test)

**Interfaces:**
- Consumes: `AudiobookRecord.author`, `NoteRecord.id`, `Flashcard.id` (already present on the records).
- Produces (used by Task 4's renderer):
  - `StudyNotesExportService.Book.author: String?` (defaulted)
  - `StudyNotesExportService.Note.id: String?` (defaulted)
  - `StudyNotesExportService.Card.id: String?` (defaulted)
- All existing call sites keep compiling because every new field is defaulted; manual-export rendering does not read the new fields.

- [ ] **Step 1: Write the failing test**

Append to `EchoTests/StudyNotesExportServiceTests.swift`:

```swift
    @Test func databaseSourcePopulatesCaptureIDsAndAuthor() throws {
        let db = try DatabaseService(inMemory: ())
        let bookID = "file:///books/tides/"
        try AudiobookDAO(db: db.writer).insert(
            AudiobookRecord(
                id: bookID, title: "The Field Guide to Tides",
                author: "M. Ostrander", duration: 3600, fileCount: 1,
                addedAt: "2026-07-01T00:00:00Z"))
        try NoteDAO(db: db.writer).insert(
            NoteRecord(
                id: "note-1", audiobookID: bookID, text: "Neap = nipped range",
                mediaTimestamp: 760, realTimestamp: nil, isEnabled: true,
                playlistPosition: nil, createdAt: "2026-07-01T20:58:31Z",
                modifiedAt: "2026-07-01T20:58:31Z"))

        let source = StudyNotesExportDatabaseSource(databaseWriter: db.writer)

        #expect(try source.books().first?.author == "M. Ostrander")
        #expect(try source.notes(for: bookID).first?.id == "note-1")
    }
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
```

Expected: compile failure — `Book` has no `author`, `Note` has no `id`.

- [ ] **Step 3: Add the defaulted fields and populate them**

In `EchoCore/Services/StudyNotesExportService.swift`, replace the `Book` struct with:

```swift
    struct Book: Equatable {
        var id: String
        var title: String
        var author: String?
        var sourceFolderURL: URL?

        init(id: String, title: String, author: String? = nil, sourceFolderURL: URL? = nil) {
            self.id = id
            self.title = title
            self.author = author
            self.sourceFolderURL = sourceFolderURL
        }
    }
```

Add `var id: String? = nil` as the **first** property of both `Note` and `Card`:

```swift
    struct Note: Equatable {
        var id: String? = nil
        var text: String
        var timestamp: TimeInterval?
        var createdAt: String
    }

    struct Card: Equatable {
        var id: String? = nil
        var front: String
        var back: String
        var timestamp: TimeInterval?
        var endTimestamp: TimeInterval?
        var tags: String?
        var media: [String: URL]
        var createdAt: String?
    }
```

In `EchoCore/Services/StudyNotesExportDatabaseSource.swift`, update the three mappings:

```swift
    func books() throws -> [StudyNotesExportService.Book] {
        try AudiobookDAO(db: databaseWriter)
            .all()
            .map {
                StudyNotesExportService.Book(
                    id: $0.id,
                    title: $0.title,
                    author: $0.author,
                    sourceFolderURL: URL(string: $0.id)
                )
            }
    }
```

```swift
    func notes(for audiobookID: String) throws -> [StudyNotesExportService.Note] {
        try NoteDAO(db: databaseWriter)
            .notes(for: audiobookID)
            .map {
                StudyNotesExportService.Note(
                    id: $0.id,
                    text: $0.text,
                    timestamp: $0.mediaTimestamp,
                    createdAt: $0.createdAt
                )
            }
    }
```

In `cards(for:)`, add `id: $0.id,` as the first argument of the `StudyNotesExportService.Card(...)` call.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test-only FILTER=EchoTests/StudyNotesExportServiceTests
```

Expected: all pass, including the pre-existing manual-export tests (behavior unchanged).

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/StudyNotesExportService.swift EchoCore/Services/StudyNotesExportDatabaseSource.swift EchoTests/StudyNotesExportServiceTests.swift
git commit -m "feat(export): carry capture ids and author through export DTOs"
```

---

### Task 4: AutoExportMarkdown — Deterministic Renderer

**Files:**
- Create: `EchoCore/Services/AutoExportMarkdown.swift`
- Create: `EchoTests/AutoExportMarkdownTests.swift`

**Interfaces:**
- Consumes: `StudyNotesExportService.Note`/`.Card`/`.ChapterEntry`, `Bookmark`, `SafeFileName.sanitizeForFilename(_:)`, CryptoKit `SHA256`.
- Produces (used by Task 5):
  - `AutoExportMarkdown.BookContext { id, title, author: String?, chapters: [StudyNotesExportService.ChapterEntry] }`
  - `AutoExportMarkdown.render(book:bookmarks:notes:cards:) -> String`
  - `AutoExportMarkdown.fileName(bookID:title:) -> String`
  - `AutoExportMarkdown.bookKey(bookID:) -> String`
  - `AutoExportMarkdown.sha256Hex(_:) -> String`

- [ ] **Step 1: Write the failing tests**

Create `EchoTests/AutoExportMarkdownTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct AutoExportMarkdownTests {
    private var book: AutoExportMarkdown.BookContext {
        AutoExportMarkdown.BookContext(
            id: "file:///books/tides/",
            title: "The Field Guide to Tides",
            author: "M. Ostrander",
            chapters: [
                StudyNotesExportService.ChapterEntry(title: "1. Reading the Water", startSeconds: 0),
                StudyNotesExportService.ChapterEntry(title: "2. Why Two Tides a Day", startSeconds: 1800),
            ]
        )
    }

    @Test func renderIsDeterministicWithStableMarkersAndChapterAttribution() throws {
        let bookmark = Bookmark(
            id: try #require(UUID(uuidString: "7C4A8D09-1E4B-4F6A-9C0D-2B5E8A7F3C11")),
            title: "Spring tide mechanics",
            timestamp: 2472,
            note: "Alignment stacks the bulges",
            voiceMemoFileName: "memo.m4a"
        )
        let note = StudyNotesExportService.Note(
            id: "note-1", text: "Neap = nipped range",
            timestamp: 760, createdAt: "2026-07-01T20:58:31Z")
        let card = StudyNotesExportService.Card(
            id: "card-1", front: "What is slack water?",
            back: "Near-zero flow at reversal", timestamp: 3483, endTimestamp: nil,
            tags: "tides", media: ["snippet.m4a": URL(fileURLWithPath: "/tmp/snippet.m4a")],
            createdAt: "2026-07-01T21:40:12Z")

        let first = AutoExportMarkdown.render(
            book: book, bookmarks: [bookmark], notes: [note], cards: [card])
        let second = AutoExportMarkdown.render(
            book: book, bookmarks: [bookmark], notes: [note], cards: [card])

        // Determinism: identical inputs must render byte-identical output.
        #expect(first == second)

        #expect(first.hasPrefix("---\ntype: echo-study-export\nversion: 1\n"))
        #expect(first.contains("book: \"The Field Guide to Tides\""))
        #expect(first.contains("author: \"M. Ostrander\""))
        #expect(first.contains("book_key: \(AutoExportMarkdown.bookKey(bookID: book.id))"))

        #expect(first.contains("<!-- echo:bookmark 7C4A8D09-1E4B-4F6A-9C0D-2B5E8A7F3C11 -->"))
        #expect(first.contains("<!-- echo:note note-1 -->"))
        #expect(first.contains("<!-- echo:card card-1 -->"))

        // 2472 s falls in chapter 2; 760 s in chapter 1.
        #expect(first.contains("- Chapter: 2. Why Two Tides a Day"))
        #expect(first.contains("- Chapter: 1. Reading the Water"))

        // Bookmarks carry the only deep link that exists today.
        #expect(first.contains(
            "- Open in Echo: echoaudio://open/bookmark/7C4A8D09-1E4B-4F6A-9C0D-2B5E8A7F3C11"))

        // v1 is text-only: assets are named, never copied or linked.
        #expect(first.contains("- Voice memo: attached in Echo (not exported)"))
        #expect(first.contains("- Media: snippet.m4a (attached in Echo; not exported)"))
        #expect(!first.contains("assets/"))
    }

    @Test func fileNamesAreStablePerBookAndDistinctAcrossTitleCollisions() {
        let a = AutoExportMarkdown.fileName(bookID: "file:///books/a/", title: "Same Title")
        let b = AutoExportMarkdown.fileName(bookID: "file:///books/b/", title: "Same Title")
        #expect(a != b)
        #expect(a.hasSuffix(".md"))
        #expect(a.contains(AutoExportMarkdown.bookKey(bookID: "file:///books/a/")))

        // A title edit changes the readable stem but keeps the stable key.
        let renamed = AutoExportMarkdown.fileName(bookID: "file:///books/a/", title: "New Title")
        #expect(renamed.contains(AutoExportMarkdown.bookKey(bookID: "file:///books/a/")))
        #expect(renamed != a)
    }

    @Test func timestamplessCapturesRenderWithoutChapterOrClock() {
        let note = StudyNotesExportService.Note(
            id: "note-2", text: "General thought", timestamp: nil,
            createdAt: "2026-07-01T22:00:00Z")
        let output = AutoExportMarkdown.render(
            book: book, bookmarks: [], notes: [note], cards: [])
        #expect(output.contains("### Note"))
        #expect(!output.contains("- Chapter:"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
```

Expected: compile failure — `AutoExportMarkdown` does not exist.

- [ ] **Step 3: Create the renderer**

Create `EchoCore/Services/AutoExportMarkdown.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Foundation

/// Deterministic Markdown rendering for auto-export mirror files. Pure/static
/// (the `LibraryAccess` testability shape): identical inputs render
/// byte-identical output — which is what makes SHA-256 skip-if-unchanged and
/// idempotent re-export trivial. No export timestamps appear in the output.
/// See docs/superpowers/specs/2026-07-02-auto-export-to-folder-design.md.
enum AutoExportMarkdown {
    struct BookContext: Equatable {
        var id: String
        var title: String
        var author: String?
        var chapters: [StudyNotesExportService.ChapterEntry]
    }

    /// First 8 hex chars of SHA-256 of the audiobook id: a stable book
    /// identity that survives title edits and keeps the raw device path out
    /// of the exported file.
    static func bookKey(bookID: String) -> String {
        String(sha256Hex(bookID).prefix(8))
    }

    static func fileName(bookID: String, title: String) -> String {
        let base = SafeFileName.sanitizeForFilename(title)
        let stem = base.isEmpty ? "Book" : base
        return "\(stem)-\(bookKey(bookID: bookID)).md"
    }

    static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func render(
        book: BookContext,
        bookmarks: [Bookmark],
        notes: [StudyNotesExportService.Note],
        cards: [StudyNotesExportService.Card]
    ) -> String {
        var md = "---\ntype: echo-study-export\nversion: 1\n"
        md += "book: \"\(yaml(book.title))\"\n"
        if let author = book.author, !author.isEmpty {
            md += "author: \"\(yaml(author))\"\n"
        }
        md += "book_key: \(bookKey(bookID: book.id))\n---\n\n"
        md += "# \(inline(book.title))\n"

        let sortedBookmarks = bookmarks.sorted {
            ($0.timestamp, $0.id.uuidString) < ($1.timestamp, $1.id.uuidString)
        }
        if !sortedBookmarks.isEmpty {
            md += "\n## Bookmarks\n"
            for bookmark in sortedBookmarks {
                md += bookmarkEntry(bookmark, chapters: book.chapters)
            }
        }

        let sortedNotes = notes.sorted {
            sortKey($0.timestamp, $0.createdAt, $0.id ?? "")
                < sortKey($1.timestamp, $1.createdAt, $1.id ?? "")
        }
        if !sortedNotes.isEmpty {
            md += "\n## Notes\n"
            for note in sortedNotes {
                md += noteEntry(note, chapters: book.chapters)
            }
        }

        let sortedCards = cards.sorted {
            sortKey($0.timestamp, $0.createdAt ?? "", $0.id ?? "")
                < sortKey($1.timestamp, $1.createdAt ?? "", $1.id ?? "")
        }
        if !sortedCards.isEmpty {
            md += "\n## Flashcards\n"
            for card in sortedCards {
                md += cardEntry(card, chapters: book.chapters)
            }
        }

        return md
    }

    /// Last chapter that starts at or before the capture timestamp.
    static func chapterTitle(
        at timestamp: TimeInterval,
        in chapters: [StudyNotesExportService.ChapterEntry]
    ) -> String? {
        chapters
            .filter { $0.startSeconds <= timestamp }
            .max(by: { $0.startSeconds < $1.startSeconds })?
            .title
    }

    // MARK: - Entries

    private static func bookmarkEntry(
        _ bookmark: Bookmark, chapters: [StudyNotesExportService.ChapterEntry]
    ) -> String {
        // Location fields (latitude/longitude/placeName) are deliberately not
        // exported: plaintext files in a synced folder are the wrong place
        // for location traces (spec privacy rule).
        var entry = "\n<!-- echo:bookmark \(bookmark.id.uuidString) -->\n"
        entry += "### \(formatHMS(bookmark.timestamp)) — \(inline(bookmark.title))\n"
        entry += "- Type: bookmark\n"
        if let chapter = chapterTitle(at: bookmark.timestamp, in: chapters) {
            entry += "- Chapter: \(inline(chapter))\n"
        }
        entry += "- Open in Echo: echoaudio://open/bookmark/\(bookmark.id.uuidString)\n"
        if bookmark.voiceMemoFileName != nil {
            entry += "- Voice memo: attached in Echo (not exported)\n"
        }
        if bookmark.bookmarkImageFileName != nil {
            entry += "- Photo: attached in Echo (not exported)\n"
        }
        if let note = bookmark.note, !note.isEmpty {
            entry += "\n> \(inline(note))\n"
        }
        return entry
    }

    private static func noteEntry(
        _ note: StudyNotesExportService.Note,
        chapters: [StudyNotesExportService.ChapterEntry]
    ) -> String {
        var entry = "\n<!-- echo:note \(note.id ?? "unidentified") -->\n"
        if let timestamp = note.timestamp {
            entry += "### \(formatHMS(timestamp)) — Note\n"
        } else {
            entry += "### Note\n"
        }
        entry += "- Type: note\n"
        if let timestamp = note.timestamp,
            let chapter = chapterTitle(at: timestamp, in: chapters)
        {
            entry += "- Chapter: \(inline(chapter))\n"
        }
        entry += "- Created: \(note.createdAt)\n"
        entry += "\n> \(inline(note.text))\n"
        return entry
    }

    private static func cardEntry(
        _ card: StudyNotesExportService.Card,
        chapters: [StudyNotesExportService.ChapterEntry]
    ) -> String {
        var entry = "\n<!-- echo:card \(card.id ?? "unidentified") -->\n"
        if let timestamp = card.timestamp {
            entry += "### \(formatHMS(timestamp)) — Flashcard\n"
        } else {
            entry += "### Flashcard\n"
        }
        entry += "- Type: flashcard\n"
        if let timestamp = card.timestamp,
            let chapter = chapterTitle(at: timestamp, in: chapters)
        {
            entry += "- Chapter: \(inline(chapter))\n"
        }
        if let createdAt = card.createdAt {
            entry += "- Created: \(createdAt)\n"
        }
        if let tags = card.tags?.trimmingCharacters(in: .whitespacesAndNewlines), !tags.isEmpty {
            entry += "- Tags: \(inline(tags))\n"
        }
        if !card.media.isEmpty {
            let names = card.media.keys.sorted().map(inline).joined(separator: ", ")
            entry += "- Media: \(names) (attached in Echo; not exported)\n"
        }
        entry += "\n**Q:** \(inline(card.front))\n"
        entry += "**A:** \(inline(card.back))\n"
        return entry
    }

    // MARK: - Helpers

    private static func sortKey(
        _ timestamp: TimeInterval?, _ createdAt: String, _ id: String
    ) -> (TimeInterval, String, String) {
        (timestamp ?? .greatestFiniteMagnitude, createdAt, id)
    }

    private static func formatHMS(_ time: TimeInterval) -> String {
        let seconds = Int(time.rounded())
        return String(
            format: "%02d:%02d:%02d",
            seconds / 3600, (seconds % 3600) / 60, seconds % 60)
    }

    private static func inline(_ text: String) -> String {
        text
            .replacing("\\", with: "\\\\")
            .replacing("[", with: "\\[")
            .replacing("]", with: "\\]")
            .replacing("\n", with: " ")
    }

    private static func yaml(_ text: String) -> String {
        text
            .replacing("\\", with: "\\\\")
            .replacing("\"", with: "\\\"")
            .replacing("\n", with: " ")
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test-only FILTER=EchoTests/AutoExportMarkdownTests
```

Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/AutoExportMarkdown.swift EchoTests/AutoExportMarkdownTests.swift
git commit -m "feat(export): deterministic auto-export markdown renderer"
```

---

### Task 5: AutoExportService — Export Pass

**Files:**
- Create: `EchoCore/Services/AutoExportService.swift`
- Create: `EchoTests/AutoExportServiceTests.swift`

**Interfaces:**
- Consumes: `StudyAutoExportDAO`, `AutoExportMarkdown`, `StudyNotesExportDatabaseSource`, `LibraryAccess.makeBookmark(for:)`/`resolveURL(from:)`, `DatabaseService.writer`.
- Produces (used by Tasks 6–8):
  - `AutoExportService(database:isEnabled:debounce:)` — `@MainActor @Observable final class`
  - `AutoExportService.PassOutcome { exported, skipped, failed: Int, needsRepick: Bool }`
  - `static func markCapturedBooksDirty(writer:) throws` (main-actor, like every other DB consumer under the project's MainActor default isolation)
  - `static func runPass(writer:) async -> PassOutcome` (main-actor async; the `NSFileCoordinator` file IO — the only part that can stall on iCloud — runs inside detached tasks off the main thread)
  - `AutoExportService.subfolderName == "Echo Study Notes"`
  - Instance API: `flushNow() async`, `enableAndBaseline() async`, `destinationPicked(url:)`, `clearDestination()`, published `destinationDisplayPath`, `needsFolderRepick`, `lastExportAt`, `lastErrorSummary`
- Note: `start()` (observation + debounce) is added in Task 6.

- [ ] **Step 1: Write the failing tests**

Create `EchoTests/AutoExportServiceTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

struct AutoExportServiceTests {
    private let bookID = "file:///books/tides/"

    private func makeTempDestination() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "auto-export-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func saveDestination(_ db: DatabaseService, at url: URL) throws {
        // Plain file-URL bookmarks need no security scope in tests — the
        // Library suites already rely on this.
        let bookmark = try #require(LibraryAccess.makeBookmark(for: url))
        try StudyAutoExportDAO(db: db.writer)
            .saveDestination(bookmark: bookmark, displayPath: url.path)
    }

    private func seedBookWithNote(_ db: DatabaseService) throws {
        try AudiobookDAO(db: db.writer).insert(
            AudiobookRecord(
                id: bookID, title: "The Field Guide to Tides",
                author: "M. Ostrander", duration: 3600, fileCount: 1,
                addedAt: "2026-07-01T00:00:00Z"))
        try NoteDAO(db: db.writer).insert(
            NoteRecord(
                id: "note-1", audiobookID: bookID, text: "Neap = nipped range",
                mediaTimestamp: 760, realTimestamp: nil, isEnabled: true,
                playlistPosition: nil, createdAt: "2026-07-01T20:58:31Z",
                modifiedAt: "2026-07-01T20:58:31Z"))
    }

    private func mirrorURL(in destination: URL) -> URL {
        destination
            .appending(path: AutoExportService.subfolderName, directoryHint: .isDirectory)
            .appending(
                path: AutoExportMarkdown.fileName(
                    bookID: bookID, title: "The Field Guide to Tides"),
                directoryHint: .notDirectory)
    }

    @Test func passExportsDirtyBooksAndClearsDirty() async throws {
        let db = try DatabaseService(inMemory: ())
        let destination = try makeTempDestination()
        defer { try? FileManager.default.removeItem(at: destination) }
        try saveDestination(db, at: destination)
        try seedBookWithNote(db)

        try AutoExportService.markCapturedBooksDirty(writer: db.writer)
        let outcome = await AutoExportService.runPass(writer: db.writer)

        #expect(outcome.exported == 1)
        #expect(outcome.failed == 0)
        let content = try String(contentsOf: mirrorURL(in: destination), encoding: .utf8)
        #expect(content.contains("<!-- echo:note note-1 -->"))
        #expect(try StudyAutoExportDAO(db: db.writer).dirtyStates().isEmpty)
    }

    @Test func unchangedContentSkipsTheRewrite() async throws {
        let db = try DatabaseService(inMemory: ())
        let destination = try makeTempDestination()
        defer { try? FileManager.default.removeItem(at: destination) }
        try saveDestination(db, at: destination)
        try seedBookWithNote(db)

        try AutoExportService.markCapturedBooksDirty(writer: db.writer)
        _ = await AutoExportService.runPass(writer: db.writer)
        let firstStamp = try FileManager.default
            .attributesOfItem(atPath: mirrorURL(in: destination).path)[.modificationDate]

        // Same database state, marked dirty again: must skip, not rewrite.
        try AutoExportService.markCapturedBooksDirty(writer: db.writer)
        let outcome = await AutoExportService.runPass(writer: db.writer)

        #expect(outcome.skipped == 1)
        #expect(outcome.exported == 0)
        let secondStamp = try FileManager.default
            .attributesOfItem(atPath: mirrorURL(in: destination).path)[.modificationDate]
        #expect(firstStamp as? Date == secondStamp as? Date)
    }

    @Test func unresolvableDestinationSetsNeedsRepickAndKeepsDirty() async throws {
        let db = try DatabaseService(inMemory: ())
        try StudyAutoExportDAO(db: db.writer)
            .saveDestination(bookmark: Data([0x00, 0x01]), displayPath: "/gone")
        try seedBookWithNote(db)

        try AutoExportService.markCapturedBooksDirty(writer: db.writer)
        let outcome = await AutoExportService.runPass(writer: db.writer)

        #expect(outcome.needsRepick == true)
        #expect(outcome.exported == 0)
        #expect(try #require(try StudyAutoExportDAO(db: db.writer).destination()).needsRepick)
        #expect(try StudyAutoExportDAO(db: db.writer).dirtyStates().count == 1)
    }

    @Test func titleRenameReplacesTheOldMirrorFile() async throws {
        let db = try DatabaseService(inMemory: ())
        let destination = try makeTempDestination()
        defer { try? FileManager.default.removeItem(at: destination) }
        try saveDestination(db, at: destination)
        try seedBookWithNote(db)

        try AutoExportService.markCapturedBooksDirty(writer: db.writer)
        _ = await AutoExportService.runPass(writer: db.writer)
        let oldURL = mirrorURL(in: destination)
        #expect(FileManager.default.fileExists(atPath: oldURL.path))

        var record = try #require(try AudiobookDAO(db: db.writer).get(bookID))
        record.title = "Tides, Revised"
        try AudiobookDAO(db: db.writer).save(record)

        try AutoExportService.markCapturedBooksDirty(writer: db.writer)
        _ = await AutoExportService.runPass(writer: db.writer)

        let newURL = destination
            .appending(path: AutoExportService.subfolderName, directoryHint: .isDirectory)
            .appending(
                path: AutoExportMarkdown.fileName(bookID: bookID, title: "Tides, Revised"),
                directoryHint: .notDirectory)
        #expect(FileManager.default.fileExists(atPath: newURL.path))
        #expect(!FileManager.default.fileExists(atPath: oldURL.path))
    }

    @Test func booksWithNoRemainingCapturesLoseTheirMirror() async throws {
        let db = try DatabaseService(inMemory: ())
        let destination = try makeTempDestination()
        defer { try? FileManager.default.removeItem(at: destination) }
        try saveDestination(db, at: destination)
        try seedBookWithNote(db)

        try AutoExportService.markCapturedBooksDirty(writer: db.writer)
        _ = await AutoExportService.runPass(writer: db.writer)
        #expect(FileManager.default.fileExists(atPath: mirrorURL(in: destination).path))

        try db.writer.write { db in
            _ = try NoteRecord.deleteAll(db)
        }
        try StudyAutoExportDAO(db: db.writer).markDirty(bookIDs: [bookID])
        _ = await AutoExportService.runPass(writer: db.writer)

        #expect(!FileManager.default.fileExists(atPath: mirrorURL(in: destination).path))
        #expect(try StudyAutoExportDAO(db: db.writer).state(for: bookID) == nil)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
```

Expected: compile failure — `AutoExportService` does not exist.

- [ ] **Step 3: Create the service**

Create `EchoCore/Services/AutoExportService.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import os.log

/// Pushes Markdown mirrors of study captures into a user-picked folder.
/// The database is the source of truth; exported files are deterministic
/// projections of it, so the persisted per-book dirty flags in
/// `study_export_state` are a retry outbox that can never lose data.
/// Never reads destination files; only whole-file atomic rewrites.
/// See docs/superpowers/specs/2026-07-02-auto-export-to-folder-design.md.
@MainActor
@Observable
final class AutoExportService {
    nonisolated static let subfolderName = "Echo Study Notes"
    private nonisolated static let logger = Logger(category: "AutoExport")

    private(set) var destinationDisplayPath: String?
    private(set) var needsFolderRepick = false
    private(set) var lastExportAt: Date?
    private(set) var lastErrorSummary: String?

    @ObservationIgnored private let database: DatabaseService
    @ObservationIgnored private let isEnabled: () -> Bool
    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private var debounceTask: Task<Void, Never>?

    init(
        database: DatabaseService,
        isEnabled: @escaping () -> Bool,
        debounce: Duration = .seconds(5)
    ) {
        self.database = database
        self.isEnabled = isEnabled
        self.debounce = debounce
        refreshStatus()
    }

    // MARK: - Instance API

    /// Session-end flush (scenePhase background/inactive): bypass the debounce.
    func flushNow() async {
        guard isEnabled() else { return }
        debounceTask?.cancel()
        await markDirtyAndExport()
    }

    /// Full baseline: called when the toggle turns on or the folder changes.
    func enableAndBaseline() async {
        await markDirtyAndExport()
    }

    func destinationPicked(url: URL) {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        guard let bookmark = LibraryAccess.makeBookmark(for: url) else {
            lastErrorSummary = "Couldn't keep access to that folder — pick it again."
            return
        }
        do {
            try StudyAutoExportDAO(db: database.writer)
                .saveDestination(bookmark: bookmark, displayPath: url.path)
            needsFolderRepick = false
            destinationDisplayPath = url.path
            lastErrorSummary = nil
            Task { await enableAndBaseline() }
        } catch {
            lastErrorSummary = "Couldn't save the folder choice."
            Self.logger.error("saveDestination failed: \(error.localizedDescription)")
        }
    }

    func clearDestination() {
        try? StudyAutoExportDAO(db: database.writer).clearDestination()
        destinationDisplayPath = nil
        needsFolderRepick = false
    }

    // MARK: - Private

    private func refreshStatus() {
        let destination = try? StudyAutoExportDAO(db: database.writer).destination()
        destinationDisplayPath = destination?.displayPath
        needsFolderRepick = destination?.needsRepick ?? false
    }

    private func markDirtyAndExport() async {
        let writer = database.writer
        do {
            try Self.markCapturedBooksDirty(writer: writer)
        } catch {
            Self.logger.error("markCapturedBooksDirty failed: \(error.localizedDescription)")
        }
        let outcome = await Self.runPass(writer: writer)
        if outcome.exported > 0 || outcome.skipped > 0 {
            lastExportAt = .now
        }
        needsFolderRepick = outcome.needsRepick
        if outcome.needsRepick {
            lastErrorSummary = "The export folder moved or is unavailable. Re-select it to resume."
        } else if outcome.failed > 0 {
            lastErrorSummary = "Last export failed — will retry."
        } else {
            lastErrorSummary = nil
        }
    }
}

// MARK: - Export pass (unit-tested directly)
// The pass is main-actor async — the isolation every other DB consumer in
// Echo uses (`StudyNotesExportDatabaseSource`, the DAOs, and `LibraryAccess`
// are implicitly @MainActor under the project's MainActor default isolation).
// SQLite reads and rendering are fast, per-book, and SHA-skipped; the only
// calls that can stall — NSFileCoordinator IO against an iCloud folder — run
// inside detached tasks off the main thread.

extension AutoExportService {
    struct PassOutcome: Equatable {
        var exported = 0
        var skipped = 0
        var failed = 0
        var needsRepick = false
    }

    /// Marks every book that currently has captures dirty. Cheap relative to
    /// capture frequency; correctness comes from re-rendering, and the SHA
    /// skip in `runPass` keeps redundant work write-free.
    static func markCapturedBooksDirty(writer: DatabaseWriter) throws {
        let source = StudyNotesExportDatabaseSource(databaseWriter: writer)
        let dao = StudyAutoExportDAO(db: writer)
        var dirtyIDs: [String] = []
        for book in try source.books() {
            let hasCaptures =
                !(try source.bookmarks(for: book.id)).isEmpty
                || !(try source.notes(for: book.id)).isEmpty
                || !(try source.cards(for: book.id)).isEmpty
            if hasCaptures { dirtyIDs.append(book.id) }
        }
        try dao.markDirty(bookIDs: dirtyIDs)
    }

    /// Exports every dirty book to the stored destination. Per-book failures
    /// never abort the pass; the destination is never read, only written.
    static func runPass(writer: DatabaseWriter) async -> PassOutcome {
        var outcome = PassOutcome()
        let dao = StudyAutoExportDAO(db: writer)

        guard let destination = try? dao.destination() else { return outcome }
        guard let resolved = LibraryAccess.resolveURL(from: destination.bookmark) else {
            try? dao.setNeedsRepick(true)
            outcome.needsRepick = true
            return outcome
        }
        if resolved.isStale, let refreshed = LibraryAccess.makeBookmark(for: resolved.url) {
            // Folder moved or was renamed: self-heal the stored grant.
            try? dao.saveDestination(bookmark: refreshed, displayPath: resolved.url.path)
        }

        let didStart = resolved.url.startAccessingSecurityScopedResource()
        defer { if didStart { resolved.url.stopAccessingSecurityScopedResource() } }

        let root = resolved.url.appending(path: subfolderName, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            logger.error("Cannot create export subfolder: \(error.localizedDescription)")
            outcome.failed += 1
            return outcome
        }

        let source = StudyNotesExportDatabaseSource(databaseWriter: writer)
        guard
            let books = try? source.books(),
            let dirty = try? dao.dirtyStates()
        else {
            outcome.failed += 1
            return outcome
        }
        let booksByID = Dictionary(uniqueKeysWithValues: books.map { ($0.id, $0) })

        for state in dirty {
            do {
                switch try await exportOne(
                    state: state, booksByID: booksByID, source: source,
                    dao: dao, root: root)
                {
                case .exported: outcome.exported += 1
                case .skipped: outcome.skipped += 1
                case .removed: break
                }
            } catch {
                try? dao.recordFailure(bookID: state.bookId, error: error.localizedDescription)
                outcome.failed += 1
                logger.error("Export failed for a book: \(error.localizedDescription)")
            }
        }
        return outcome
    }

    private enum ExportResult {
        case exported
        case skipped
        case removed
    }

    private static func exportOne(
        state: StudyExportStateRecord,
        booksByID: [String: StudyNotesExportService.Book],
        source: StudyNotesExportDatabaseSource,
        dao: StudyAutoExportDAO,
        root: URL
    ) async throws -> ExportResult {
        func removeMirrorAndForget() async throws -> ExportResult {
            if let fileName = state.fileName {
                try? await deleteOffMain(
                    root.appending(path: fileName, directoryHint: .notDirectory))
            }
            try dao.removeState(bookID: state.bookId)
            return .removed
        }

        guard let book = booksByID[state.bookId] else {
            // Book deleted from Echo: mirror semantics remove its file.
            return try await removeMirrorAndForget()
        }

        let bookmarks = try source.bookmarks(for: book.id)
        let notes = try source.notes(for: book.id)
        let cards = try source.cards(for: book.id)
        guard !(bookmarks.isEmpty && notes.isEmpty && cards.isEmpty) else {
            return try await removeMirrorAndForget()
        }

        let chapters = try source.chapters(for: book.id)
        let markdown = AutoExportMarkdown.render(
            book: AutoExportMarkdown.BookContext(
                id: book.id, title: book.title, author: book.author, chapters: chapters),
            bookmarks: bookmarks, notes: notes, cards: cards)
        let sha = AutoExportMarkdown.sha256Hex(markdown)
        let fileName = AutoExportMarkdown.fileName(bookID: book.id, title: book.title)

        if sha == state.contentSha256, fileName == state.fileName {
            try dao.recordSuccess(
                bookID: book.id, fileName: fileName, contentSha256: sha,
                at: Date.now.ISO8601Format())
            return .skipped
        }

        try await writeOffMain(
            Data(markdown.utf8),
            to: root.appending(path: fileName, directoryHint: .notDirectory))
        if let oldName = state.fileName, oldName != fileName {
            try? await deleteOffMain(root.appending(path: oldName, directoryHint: .notDirectory))
        }
        try dao.recordSuccess(
            bookID: book.id, fileName: fileName, contentSha256: sha,
            at: Date.now.ISO8601Format())
        return .exported
    }

    // MARK: File IO — detached so iCloud stalls never touch the main thread.
    // The coordinated helpers are nonisolated *sync* functions (pure
    // Foundation, no actor state), which is what lets the detached tasks
    // call them without an actor hop.

    private static func writeOffMain(_ data: Data, to fileURL: URL) async throws {
        try await Task.detached(priority: .utility) {
            try AutoExportService.coordinatedWrite(data, to: fileURL)
        }.value
    }

    private static func deleteOffMain(_ fileURL: URL) async throws {
        try await Task.detached(priority: .utility) {
            try AutoExportService.coordinatedDelete(fileURL)
        }.value
    }

    /// Coordinated + atomic replace so iCloud (and any reader) never sees a
    /// half-written file.
    private nonisolated static func coordinatedWrite(_ data: Data, to fileURL: URL) throws {
        var coordinationError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(
            writingItemAt: fileURL, options: .forReplacing, error: &coordinationError
        ) { url in
            do { try data.write(to: url, options: .atomic) } catch { writeError = error }
        }
        if let coordinationError { throw coordinationError }
        if let writeError { throw writeError }
    }

    private nonisolated static func coordinatedDelete(_ fileURL: URL) throws {
        var coordinationError: NSError?
        var deleteError: Error?
        NSFileCoordinator().coordinate(
            writingItemAt: fileURL, options: .forDeleting, error: &coordinationError
        ) { url in
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            do { try FileManager.default.removeItem(at: url) } catch { deleteError = error }
        }
        if let coordinationError { throw coordinationError }
        if let deleteError { throw deleteError }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test-only FILTER=EchoTests/AutoExportServiceTests
```

Expected: all pass. If the modification-date comparison in `unchangedContentSkipsTheRewrite` proves flaky on the simulator's filesystem timestamp resolution, compare file contents plus `outcome.skipped`/`outcome.exported` instead — the contract under test is "no rewrite happened".

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/AutoExportService.swift EchoTests/AutoExportServiceTests.swift
git commit -m "feat(export): auto-export service export pass"
```

---

### Task 6: Capture Observation + Debounce

**Files:**
- Modify: `EchoCore/Services/AutoExportService.swift` (add `start()` + `captureDidChange()`)
- Modify: `EchoTests/AutoExportServiceTests.swift` (append the integration test)

**Interfaces:**
- Consumes: `DatabaseRegionObservation`, `NoteRecord.databaseTableName`, `BookmarkRecord.databaseTableName`, `Flashcard.databaseTableName`.
- Produces: `AutoExportService.start()` — begins observation — and `retryPendingIfAny() async` — re-runs persisted dirty rows; capture commits now trigger a debounced export.

- [ ] **Step 1: Write the failing integration test**

Append to `EchoTests/AutoExportServiceTests.swift`:

```swift
    @Test func captureCommitTriggersDebouncedExport() async throws {
        let db = try DatabaseService(inMemory: ())
        let destination = try makeTempDestination()
        defer { try? FileManager.default.removeItem(at: destination) }
        try saveDestination(db, at: destination)
        try seedBookWithNote(db)

        let service = AutoExportService(
            database: db, isEnabled: { true }, debounce: .milliseconds(50))
        service.start()

        // A fresh capture commit after start() must trigger an export.
        try NoteDAO(db: db.writer).insert(
            NoteRecord(
                id: "note-2", audiobookID: bookID, text: "Slack water window",
                mediaTimestamp: 900, realTimestamp: nil, isEnabled: true,
                playlistPosition: nil, createdAt: "2026-07-01T21:10:00Z",
                modifiedAt: "2026-07-01T21:10:00Z"))

        var exported = false
        for _ in 0..<100 {
            if let content = try? String(contentsOf: mirrorURL(in: destination), encoding: .utf8),
                content.contains("<!-- echo:note note-2 -->")
            {
                exported = true
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(exported)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
```

Expected: compile failure — `start()` does not exist.

- [ ] **Step 3: Add observation and debounce**

In `EchoCore/Services/AutoExportService.swift`, add a stored cancellable next to `debounceTask`:

```swift
    @ObservationIgnored private var observationCancellable: AnyDatabaseCancellable?
```

Add to the main class body (below `init`):

```swift
    /// Begins observing capture tables. Call once at app start. All capture
    /// paths — phone UI, watch, widget/Siri drains, macOS — commit to these
    /// three GRDB tables, so one observation covers every write site.
    func start() {
        let observation = DatabaseRegionObservation(tracking: [
            Table(NoteRecord.databaseTableName),
            Table(BookmarkRecord.databaseTableName),
            Table(Flashcard.databaseTableName),
        ])
        observationCancellable = observation.start(
            in: database.writer,
            onError: { error in
                Self.logger.error("Capture observation failed: \(error.localizedDescription)")
            },
            onChange: { [weak self] _ in
                // Delivered on the writer queue; hop to the main actor.
                Task { @MainActor [weak self] in self?.captureDidChange() }
            }
        )
        if isEnabled() {
            Task { await self.retryPendingIfAny() }
        }
    }

    /// Debounced capture trigger: coalesces bursts (typing edits, deck
    /// imports) into one export pass. `study_export_state` writes are not
    /// observed, so exports cannot re-trigger themselves.
    private func captureDidChange() {
        guard isEnabled() else { return }
        debounceTask?.cancel()
        debounceTask = Task { [debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self.markDirtyAndExport()
        }
    }

    /// If a previous pass failed or the app was killed mid-debounce,
    /// persisted dirty rows still exist — retry them. Called from `start()`
    /// and when the app returns to the foreground (wired in Task 8).
    func retryPendingIfAny() async {
        let writer = database.writer
        let hasPending = (try? StudyAutoExportDAO(db: writer).dirtyStates().isEmpty == false) ?? false
        guard hasPending else { return }
        _ = await Self.runPass(writer: writer)
        refreshStatus()
    }
```

Note: GRDB is an SPM dependency pinned at 7.11.1 (`Package.resolved`). At that version `DatabaseRegionObservation.start(in:onError:onChange:)` returns `AnyDatabaseCancellable` and both closures must be `@Sendable` (the ones above qualify). If the pin ever moves, adapt the signature — the retained-until-cancelled semantics are the contract.

- [ ] **Step 4: Run the tests to verify they pass**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test-only FILTER=EchoTests/AutoExportServiceTests
```

Expected: all pass, including the new integration test.

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/AutoExportService.swift EchoTests/AutoExportServiceTests.swift
git commit -m "feat(export): observe capture tables with debounced auto-export"
```

---

### Task 7: Settings Toggle + Study & Notes Rows (Pro-Gated)

**Files:**
- Modify: `EchoCore/Services/SettingsManager.swift` (`Defaults`, `Keys`, property, `init` read)
- Create: `EchoCore/Views/AutoExportSettingsRows.swift`
- Modify: `EchoCore/Views/SettingsView.swift` (mount after the `Section("Study & Notes")` block, which currently ends after the deck-import/export rows around line 74–100)
- Modify: `EchoTests/EchoCoreTests.swift` (settings persistence test)
- Modify: `EchoTests/SettingsExtractionTests.swift` (structural guardrails)

**Interfaces:**
- Consumes: `SettingsManager` persistence pattern, `StoreManager.isPro`, `PaywallView(context: .settings)`, `AutoExportService` published status, `.fileImporter`.
- Produces: `SettingsManager.studyAutoExportEnabled: Bool` (default `false`), `AutoExportSettingsRows` view mounted in root Settings.

- [ ] **Step 1: Write the failing tests**

Append to `EchoTests/EchoCoreTests.swift` (next to the other settings persistence tests):

```swift
    @Test func settingsPersistsStudyAutoExportEnabled() {
        let suiteName = "auto-export-\(UUID().uuidString)"
        let appGroupName = "auto-export-ag-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let appGroupDefaults = UserDefaults(suiteName: appGroupName)!
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            appGroupDefaults.removePersistentDomain(forName: appGroupName)
        }

        let settings = SettingsManager(defaults: defaults, appGroupDefaults: appGroupDefaults)
        #expect(SettingsManager.Defaults.studyAutoExportEnabled == false)
        #expect(settings.studyAutoExportEnabled == false)

        settings.studyAutoExportEnabled = true
        let reloaded = SettingsManager(defaults: defaults, appGroupDefaults: appGroupDefaults)
        #expect(reloaded.studyAutoExportEnabled == true)
    }
```

Append to `EchoTests/SettingsExtractionTests.swift`:

```swift
    @Test func studySettingsExposeAutoExportRows() throws {
        let rows = try Self.source(named: "AutoExportSettingsRows.swift")
        #expect(rows.contains("Auto-Export Study Notes"))
        #expect(rows.contains(".fileImporter"))
        #expect(rows.contains("allowedContentTypes: [.folder]"))
        #expect(rows.contains("store.isPro"))
        #expect(rows.contains("PaywallView(context: .settings)"))

        let shell = try Self.source(named: "SettingsView.swift")
        #expect(shell.contains("AutoExportSettingsRows()"))
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
```

Expected: compile failure on `studyAutoExportEnabled`; the structural test fails on the missing file.

- [ ] **Step 3: Add the setting**

In `EchoCore/Services/SettingsManager.swift`:

In the `Defaults` enum, next to the other `study*` defaults:

```swift
        static let studyAutoExportEnabled = false
```

In the `Keys` enum, next to the other `study*` keys:

```swift
        static let studyAutoExportEnabled = "studyAutoExportEnabled"
```

Add the property alongside the other study settings properties, following the exact `didSet { defaults.set(…) }` pattern the file already uses:

```swift
    var studyAutoExportEnabled: Bool {
        didSet { defaults.set(studyAutoExportEnabled, forKey: Keys.studyAutoExportEnabled) }
    }
```

In `init`, next to where the other study keys are read, following the file's existing read pattern:

```swift
        studyAutoExportEnabled =
            defaults.object(forKey: Keys.studyAutoExportEnabled) as? Bool
            ?? Defaults.studyAutoExportEnabled
```

- [ ] **Step 4: Create the settings rows**

Create `EchoCore/Views/AutoExportSettingsRows.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UniformTypeIdentifiers

/// Study & Notes rows for auto-export: Pro-gated toggle, destination folder
/// picker, and a passive status footer. Renders as its own `Section` so the
/// footer and `fileImporter` stay attached to these rows.
struct AutoExportSettingsRows: View {
    @Environment(SettingsManager.self) private var settings
    @Environment(StoreManager.self) private var store
    @Environment(AutoExportService.self) private var autoExport
    @State private var showingFolderPicker = false
    @State private var showingPaywall = false

    var body: some View {
        Section {
            Toggle("Auto-Export Study Notes", isOn: enabledBinding)

            if settings.studyAutoExportEnabled {
                Button {
                    showingFolderPicker = true
                } label: {
                    LabeledContent("Export Folder") {
                        Text(folderLabel)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                    }
                }
            }
        } header: {
            Text("Auto-Export")
        } footer: {
            Text(statusText)
        }
        .fileImporter(
            isPresented: $showingFolderPicker,
            allowedContentTypes: [.folder]
        ) { result in
            if case .success(let url) = result {
                autoExport.destinationPicked(url: url)
            }
        }
        .sheet(isPresented: $showingPaywall) {
            PaywallView(context: .settings)
        }
    }

    private var enabledBinding: Binding<Bool> {
        Binding(
            get: { settings.studyAutoExportEnabled },
            set: { newValue in
                // Entitlement gate — see the spec's "Settings & gating"
                // (flagged "Dan ratifies").
                guard !newValue || store.isPro else {
                    showingPaywall = true
                    return
                }
                settings.studyAutoExportEnabled = newValue
                if newValue {
                    Task { await autoExport.enableAndBaseline() }
                }
            }
        )
    }

    private var folderLabel: String {
        if autoExport.needsFolderRepick { return "Folder unavailable — re-select" }
        guard let path = autoExport.destinationDisplayPath else { return "Choose…" }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private var statusText: String {
        guard settings.studyAutoExportEnabled else {
            return "Keeps a Markdown copy of your notes, bookmarks, and flashcards "
                + "in a folder you choose — for example an iCloud Drive folder "
                + "your Mac tools can read."
        }
        if autoExport.needsFolderRepick {
            return "The export folder moved or is unavailable. Re-select it to resume."
        }
        if autoExport.destinationDisplayPath == nil {
            return "Choose a folder to start exporting."
        }
        if let error = autoExport.lastErrorSummary { return error }
        if let last = autoExport.lastExportAt {
            return "Last export \(last.formatted(.relative(presentation: .named)))."
        }
        return "Waiting for the first export."
    }
}
```

In `EchoCore/Views/SettingsView.swift`, add `AutoExportSettingsRows()` as a sibling section immediately after the closing brace of `Section("Study & Notes") { … }`:

```swift
                AutoExportSettingsRows()
```

If `StoreManager` is not already available via `@Environment` at this point in the view tree, inject it the same way the paywall-presenting settings screens receive it (see `ProTranscriptsSettingsView` and the `.environment` calls in `EchoCoreApp`).

- [ ] **Step 5: Run the tests to verify they pass**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test-only FILTER=EchoTests/EchoCoreTests
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test-only FILTER=EchoTests/SettingsExtractionTests
```

Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add EchoCore/Services/SettingsManager.swift EchoCore/Views/AutoExportSettingsRows.swift EchoCore/Views/SettingsView.swift EchoTests/EchoCoreTests.swift EchoTests/SettingsExtractionTests.swift
git commit -m "feat(settings): auto-export toggle, folder picker, and status rows"
```

---

### Task 8: App Wiring — Construction + Session-End Flush

**Files:**
- Modify: `EchoCore/EchoCoreApp.swift` (construct + inject the service)
- Modify: `EchoCore/Views/RootTabView.swift:526-551` (the existing `.onChange(of: scenePhase)`; the `.background || .inactive` branch starts at :532)
- Modify: `EchoTests/SettingsExtractionTests.swift` (wiring guardrail)

**Interfaces:**
- Consumes: `AutoExportService(database:isEnabled:)`, `AutoExportService.start()`, `flushNow()`, the existing `@State`/`.environment` wiring in `EchoCoreApp`, the existing `scenePhase` `onChange` in `RootTabView`.
- Produces: a started `AutoExportService` in the SwiftUI environment; captures flush before the app suspends.

- [ ] **Step 1: Write the failing structural test**

Append to `EchoTests/SettingsExtractionTests.swift`:

```swift
    @Test func rootTabViewFlushesAutoExportOnBackground() throws {
        let source = try Self.source(named: "RootTabView.swift")
        #expect(source.contains("autoExport.flushNow()"))
        #expect(source.contains("autoExport.retryPendingIfAny()"))
    }
```

- [ ] **Step 2: Run the test to verify it fails**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test-only FILTER=EchoTests/SettingsExtractionTests
```

Expected: `rootTabViewFlushesAutoExportOnBackground` fails.

- [ ] **Step 3: Wire the service**

In `EchoCore/EchoCoreApp.swift`, add a state slot next to `freeTierGate` (same implicitly-unwrapped pattern):

```swift
    @State private var autoExport: AutoExportService!
```

In `init()`, after the `DatabaseService` setup block (where `initialModel.databaseService` is assigned), add:

```swift
        // Auto-export rides the same database; an in-memory fallback keeps
        // the environment populated if the on-disk database failed to open
        // (no destination row exists there, so the service stays inert). The
        // enabled check includes the Pro entitlement so a lapsed subscription
        // pauses exporting (spec: Settings & gating — Dan ratifies).
        let exportDatabase: DatabaseService
        if let db = initialModel.databaseService {
            exportDatabase = db
        } else {
            // An in-memory SQLite open failing is fatal-adjacent; assign
            // unconditionally, matching the freeTierGate precedent above.
            exportDatabase = try! DatabaseService(inMemory: ())
        }
        let initialAutoExport = AutoExportService(
            database: exportDatabase,
            isEnabled: { initialSettings.studyAutoExportEnabled && initialStoreManager.isPro }
        )
        initialAutoExport.start()
        _autoExport = State(wrappedValue: initialAutoExport)
```

Where the other services are injected into the view hierarchy (the `.environment(…)` chain), add:

```swift
                .environment(autoExport)
```

In `EchoCore/Views/RootTabView.swift`, add the environment handle next to the view's other `@Environment` properties:

```swift
    @Environment(AutoExportService.self) private var autoExport
```

In the existing `scenePhase` `onChange`, at the top of the `.background || .inactive` branch (before the navigation-path persistence), add:

```swift
                // Session end: flush pending captures before iOS suspends us.
                Task { await autoExport.flushNow() }
```

In the same `onChange`, in the `newPhase == .active` branch (next to `model.drainPendingWidgetBookmarks()`), add:

```swift
                // Foreground return: retry anything a failed pass left dirty.
                Task { await autoExport.retryPendingIfAny() }
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test-only FILTER=EchoTests/SettingsExtractionTests
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test
```

Expected: structural test passes; the full unit-test suite is green (this is the last code task — run everything).

- [ ] **Step 5: Commit**

```bash
git add EchoCore/EchoCoreApp.swift EchoCore/Views/RootTabView.swift EchoTests/SettingsExtractionTests.swift
git commit -m "feat(export): wire auto-export service with session-end flush"
```

---

### Task 9: Documentation

**Files:**
- Modify: `ARCHITECTURE.md` (new subsection near the other study/export subsections)
- Modify: `CHANGELOG.md` (`[Unreleased]` ▸ `Added`)
- Modify: `docs/guides/user-manual.md` (new section in the study-notes/export area)

- [ ] **Step 1: ARCHITECTURE.md**

Add after the "Chaptered M4B Export" subsection:

```markdown
### Auto-Export Study Captures (July 2026)

When enabled (Settings ▸ Study & Notes ▸ Auto-Export), Echo continuously mirrors each book's study captures as one deterministic Markdown file per book inside an Echo-owned `Echo Study Notes/` subfolder of a user-picked destination (typically iCloud Drive, so Mac-side tooling can ingest the files). iOS cannot watch folders, so Echo pushes: `AutoExportService` (`@MainActor @Observable`) observes the `note`/`bookmark`/`flashcard` tables via GRDB `DatabaseRegionObservation` — one choke point that covers phone UI, watch, widget/Siri, and macOS write paths — debounces 5 s, and rewrites dirty books' files atomically (`NSFileCoordinator` + atomic replace). Rendering is the pure `AutoExportMarkdown` enum: YAML frontmatter (`book`, `author`, `book_key` = SHA-256-prefix of the book id), HTML-comment capture-ID markers for downstream dedup, chapter attribution by timestamp, text-only in v1 (assets and bookmark location fields are deliberately not exported). Determinism (no export timestamps in the file) enables SHA-256 skip-if-unchanged, so unchanged books cause zero iCloud churn, and destination files are never read.

**Schema V34** adds `study_export_destination` (single-row security-scoped bookmark, the `library_root` precedent) and `study_export_state` (per-book `dirty` flags = the persisted retry outbox, plus `file_name`/`content_sha256`/`last_error`). Failures keep books dirty and retry on the next trigger/foreground; an unresolvable destination sets `needs_repick` and pauses passes; a stale-but-resolvable bookmark self-heals. Status is passive (Settings footer only) — capture and playback UX are never interrupted. The manual per-book/all-books export is unchanged; auto-export is Pro-gated. The macOS Settings pane is a deliberate fast-follow.

**Test coverage:** `SchemaV34Tests`, `StudyAutoExportDAOTests`, `AutoExportMarkdownTests`, `AutoExportServiceTests`, plus settings/structural guardrails.

Design spec: `docs/superpowers/specs/2026-07-02-auto-export-to-folder-design.md`; implementation plan: `docs/superpowers/plans/2026-07-02-auto-export-to-folder.md`.
```

- [ ] **Step 2: CHANGELOG.md**

Add under `[Unreleased]` ▸ `Added`:

```markdown
- **Auto-export study captures to a folder (Schema V34, Pro):** Enable Settings ▸ Study & Notes ▸ Auto-Export, pick a folder (e.g. iCloud Drive), and Echo keeps one Markdown file per book — notes, bookmarks, and flashcards with stable capture-ID markers, chapter attribution, and YAML frontmatter — continuously up to date for external ingestion. Exports are deterministic mirrors: debounced on capture, flushed on backgrounding, atomically rewritten, SHA-skipped when unchanged, and queued durably (per-book dirty flags) when the folder is unreachable, so captures are never lost and playback is never interrupted. Text-only in v1 (audio snippets, photos, and bookmark location data are not exported); the existing manual export is unchanged. New types: `AutoExportService`, `AutoExportMarkdown`, `StudyAutoExportDAO`, `Schema_V34`, `AutoExportSettingsRows`. New tests: `SchemaV34Tests`, `StudyAutoExportDAOTests`, `AutoExportMarkdownTests`, `AutoExportServiceTests`.
```

- [ ] **Step 3: user manual**

Add to `docs/guides/user-manual.md`, next to the existing study-notes export documentation:

```markdown
## Auto-export your study notes

Echo can keep a folder of Markdown files — one per book — continuously in sync with your notes, bookmarks, and flashcards. Point it at an iCloud Drive folder and your captures appear on your Mac a few seconds after you make them, ready for whatever notes system you use there.

1. Open **Settings ▸ Study & Notes** and turn on **Auto-Export Study Notes** (Echo Pro).
2. Tap **Export Folder** and pick a folder. Echo writes into an `Echo Study Notes` subfolder it manages.
3. That's it — capture as you listen. Files update a few seconds after each capture and whenever you leave the app.

Each book becomes one Markdown file with your bookmarks, notes, and flashcards in listening order, tagged with chapter and timestamp. Voice memos, photos, and card audio stay in Echo (the file notes they exist); use **Export Study Notes** (the manual share option) when you want a zip that includes the media files. If the folder becomes unavailable — renamed, deleted, or iCloud signed out — Echo quietly queues your changes and the Settings row asks you to re-select the folder; nothing is lost.
```

> **Ratification contingency:** the "Pro" references in the CHANGELOG entry and the user manual are contingent on Dan ratifying the spec's "Settings & gating" section. If the gate is struck at PR review, remove "Pro"/"Echo Pro" from both docs (and the paywall gate from Task 7 plus the `isPro` term in Task 8's `isEnabled` closure) before merge.

- [ ] **Step 4: Verify docs build nothing is stale**

Run the repo's **doc-sync** skill (per `CLAUDE.md`'s documentation rule) and confirm `ARCHITECTURE.md`, `README.md`, `CHANGELOG.md`, and `ROADMAP.md` are consistent with the shipped feature. Update `ROADMAP.md` if it lists this feature as planned.

- [ ] **Step 5: Commit**

```bash
git add ARCHITECTURE.md CHANGELOG.md docs/guides/user-manual.md ROADMAP.md
git commit -m "docs: document study auto-export feature"
```

---

## Codex kickoff

Self-contained brief for the implementing agent (OpenAI Codex 5.5). Do not assume access to any prior conversation — everything needed is in this file and the spec.

**Repository:** `/Users/dfakkeldy/Developer/Echo` — public, GPL-3.0. Every new Swift file must start with `// SPDX-License-Identifier: GPL-3.0-or-later`. Never commit secrets, personal data, or private-repo content.

**Read first:**
1. `docs/superpowers/specs/2026-07-02-auto-export-to-folder-design.md` (the approved design — decisions and rationale)
2. This plan: `docs/superpowers/plans/2026-07-02-auto-export-to-folder.md`
3. `CLAUDE.md` and `ARCHITECTURE.md` (conventions; especially the DI rule: concrete types + constructor/closure injection, **no protocols or mocks**)

**Branch setup (the repo's promotion ladder — feature work is based on `nightly`, never `main`):**

```bash
cd /Users/dfakkeldy/Developer/Echo
git fetch origin nightly
git checkout -b feature/study-auto-export origin/nightly
git status --short --branch   # confirm clean and tracking origin/nightly
```

**Execute** Tasks 1–9 in order, following each task's TDD steps exactly (failing test → implement → pass → commit). Conventional Commits as written in each task. File/line references were verified against `origin/nightly` @ `24610794`; if the tree has moved, re-locate anchors before editing rather than forcing stale line numbers. Task 1 Step 0's migration-number re-check is mandatory.

**Build & test — this is a 16 GB machine. Always prefix builds with the build gate, never run two xcodebuild invocations concurrently, never enable uncapped parallel testing:**

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test-only FILTER=EchoTests/<Suite>
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make test        # full suite (Task 8)
```

If the gate reports HOLD, wait and retry; check status with `~/.claude/bin/xcode-build-gate.sh --status`. UI tests are intentionally excluded from the scheme.

**Hard rules:**
- No third-party frameworks (CryptoKit / UniformTypeIdentifiers are system frameworks and fine).
- Swift Testing only; test seams are `DatabaseService(inMemory: ())` and temp directories — no new protocols, no mock classes.
- Do not change the manual export's behavior or output.
- Never export bookmark location fields; never read destination files.
- GRDB is an SPM dependency pinned at 7.11.1 (`Package.resolved`); the plan's GRDB usage was verified against that version. If the pin has moved, adapt signatures — the semantics in this plan are the contract.

**Finish:**

```bash
git push -u origin feature/study-auto-export
gh pr create --base nightly \
  --title "feat: auto-export study captures to folder" \
  --body "Implements docs/superpowers/specs/2026-07-02-auto-export-to-folder-design.md per docs/superpowers/plans/2026-07-02-auto-export-to-folder.md.

⚠️ Entitlement change for ratification: auto-export is Pro-gated (manual export stays free) — see the spec's 'Settings & gating'. Dan: ratify or strike before merge.

Schema V34 (re-confirmed free at implementation time). Docs updated (ARCHITECTURE, CHANGELOG, user manual)."
gh pr checks --watch   # fix failures and re-push until green
```

The PR must target `nightly` (never `main`/`weekly`), must not be a draft, and its body must keep the Pro-gating ratification flag prominent.
