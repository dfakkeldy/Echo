# Unified Feed — Phase 4 (New Content Types + Capture: Voice Memos & Notes, iOS) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add **two new content types** to the unified reader feed — **voice memos** and **notes** — as first-class `TimelineItemType` values and as new `ReaderCardItem` cases that thread into the collapsible feed at their EPUB document position. Ship the **capture UI** for both this phase (no half-built capture left over from earlier phases): a tap-to-record voice-memo overlay and a quick note composer, both writing rows that immediately appear in the feed. The feed's cell registry stays open/extensible so the two new item types slot in without rewriting the core feed engine.

**Architecture:** Phase 4 extends three seams established by Phases 1–3. (1) The persisted item-type tag `TimelineItemType` (`Shared/Database/TimelineItem.swift:5`) gains `.voiceMemo` and `.note`. (2) The per-row feed item enum `ReaderCardItem` (`EchoCore/Models/ReaderCardItem.swift:13`) gains `.note(NoteRecord)` and `.voiceMemo(VoiceMemoRecord)` with unique `id` prefixes; the manual `Hashable`/`Equatable` conformance is extended in lock-step. (3) The UIKit cell switch in `ReaderFeedCollectionView` (`EchoCore/Views/ReaderFeedCollectionView.swift:65`, `:247`) registers two new cell classes and gains two `case` branches. Notes get a new `epub_block_id` column (document-order positioning, mirroring `TimelineItem.epubBlockID`); voice memos are stored in a **net-new `voice_memo` table** (the existing `bookmark.voice_memo_path` is an *attachment*, not a standalone memo). One schema migration (next free version on `nightly`, see Task 1) adds the column, the table, and an index, with a `SchemaVxxTests` and the `schema-migration-reviewer`. The feed view model injects note/memo items into `parsedSections` at the right block position, mirroring the Phase 2 bookmark/card injection pattern; pure positioning math is extracted into `FeedItemInjector` and unit-tested.

**Tech Stack:** Swift 6, SwiftUI + UIKit bridging (`UIViewRepresentable`), GRDB, AVFoundation (`AVAudioRecorder`/`AVAudioPlayer` for memos), Swift Testing (`@Test`/`#expect`), `DatabaseService(inMemory:)`.

## Global Constraints

- **License header:** every new `.swift` file starts with `// SPDX-License-Identifier: GPL-3.0-or-later` on **line 1**. A SwiftFormat PostToolUse hook reflows imports on edit and can displace the SPDX header below an `import` — after editing, verify SPDX is still line 1 (a blank line after it detaches it from the import block).
- **Branch:** cut a fresh `feature/unified-feed-phase4` from `origin/nightly` (`git fetch origin nightly && git checkout -b feature/unified-feed-phase4 origin/nightly`). Phases 1–3 land on `nightly` first; rebase onto the latest `nightly` before starting so the `ReaderCardItem`/`ReaderFeedViewModel`/`ReaderFeedCollectionView` shapes match. PRs target **`nightly`**, never `main`.
- **Scope is iOS only.** `ReaderFeedViewModel` / `ReaderFeedCollectionView` / `ReaderTab` import UIKit and are not in the macOS target. macOS parity is a later phase (spec §12). New **pure** types must stay UIKit-free so macOS can reuse them later: `VoiceMemoRecord`, `VoiceMemoDAO`, the `NoteRecord` change, the schema migration, and `FeedItemInjector` go in `Shared/`; capture views and cells are iOS-only and go in `EchoCore/Views/`.
- **Out of scope this phase (do not build):** bookmarks/cards as feed items (Phase 2 — assume already present); filters / session-scope / Sessions-recap / `session_location` write path (Phase 3 — `session_location` is unimplemented and Phase 4 does NOT depend on it); the off-switch / grey-out (Phase 2); word-tap-to-seek (its own later plan); macOS parity. Do not touch `EPUBTOCSheet`.
- **Build discipline (16 GB machine):** never run two `xcodebuild` invocations concurrently. The overnight `~/Developer/echo-overnight/redo-resume.sh` (NarrationHarness) holds the **exclusive** build slot — confirm it is idle/paused before any `make build-tests`. Run all builds in the **foreground** with a long timeout (`timeout: 600000`); a subagent that backgrounds a build yields unresumably. `make build-tests` and `make test-only FILTER=…` already pass `CODE_SIGNING_ALLOWED=NO` (Makefile `CODESIGN_OFF`); the sim destination is `iPhone 17`.
- **Schema migration:** Phase 4 needs **one** migration. The recon found the highest registered migration is `"v23_audiobook_abs_provenance"` (`Shared/Database/DatabaseService.swift:115`) and the highest schema file is `Schema_V23.swift`, with no `Schema_V24.swift` in any active worktree. **Claim the next free version number on `nightly` at implementation time** — do NOT hard-code `V24` blindly; Phases 1–3 add no schema per their plans, but re-check with `ls Shared/Database/Migrations/ | sort -V` and run the `schema-migration-reviewer` agent before merging. This plan writes `V24` throughout as the *expected* number; if it is taken, rename the file, the enum, the `registerMigration` string, and the test suite consistently.

---

## Open Question Resolved (documented default — flag for owner review)

**Recon Trap 4 — voice memo: net-new table vs. `bookmark.voice_memo_path`.** The spec (§8) says voice-memo storage is "audio file + row, net-new." This plan therefore implements a **standalone `voice_memo` table** with its own `.m4a` file, NOT reusing `bookmark.voice_memo_path` (which remains the *attachment* path on a bookmark). Consequence: recording a feed voice memo is a **standalone action** — it does NOT implicitly create a bookmark. **Owner review flag:** if you would rather a memo always be a bookmark attachment (so the existing bookmark UI owns it), stop before Task 1 and say so — that collapses the migration to just the `note.epub_block_id` column and turns `.voiceMemo` into a virtual type over `bookmark WHERE voice_memo_path IS NOT NULL`. The default below assumes standalone, per the spec's "net-new" wording.

**CloudKit caution (Trap 7 / spec §7.2, §10).** The recon found **no `CKRecord` mapping for `note`** and no evidence `note`/`voice_memo` participate in CloudKit sync. Adding `note.epub_block_id` and a new `voice_memo` table is therefore safe as a local-only schema change. **Verification step (Task 1 Step 5):** grep the codebase for any CloudKit record-type registration touching `note` before merge; if one is found, the new column must be added to that record type too. Do not skip this check.

---

## File Structure

**New files**

- `Shared/Database/Migrations/Schema_V24.swift` *(create — `note.epub_block_id` column + `voice_memo` table + index; claim next free version)*
- `Shared/Database/VoiceMemoRecord.swift` *(create — GRDB record for the new `voice_memo` table)*
- `Shared/Database/DAOs/VoiceMemoDAO.swift` *(create — CRUD + positional query)*
- `Shared/Feed/FeedItemInjector.swift` *(create — pure: merge note/memo items into `[ReaderCardSection]` at block position; no UIKit/DB)*
- `EchoCore/Views/NoteFeedCell.swift` *(create — iOS UICollectionViewCell for a note row)*
- `EchoCore/Views/VoiceMemoFeedCell.swift` *(create — iOS UICollectionViewCell for a voice-memo row, play button)*
- `EchoCore/Views/FeedCaptureBar.swift` *(create — iOS SwiftUI capture overlay: "Add note" + "Record memo")*
- `EchoCore/Services/VoiceMemoRecorder.swift` *(create — iOS AVAudioRecorder wrapper for standalone memos)*
- `EchoTests/SchemaV24Tests.swift` *(create)*
- `EchoTests/VoiceMemoDAOTests.swift` *(create)*
- `EchoTests/NoteDAOEpubBlockTests.swift` *(create)*
- `EchoTests/FeedItemInjectorTests.swift` *(create)*
- `EchoTests/ReaderCardItemPhase4Tests.swift` *(create)*
- `EchoTests/TimelineItemTypePhase4Tests.swift` *(create)*

**Modified files**

- `Shared/Database/DatabaseService.swift` — register the `v24_…` migration after `v23_audiobook_abs_provenance`.
- `Shared/Database/TimelineItem.swift` — add `.voiceMemo` / `.note` enum cases; fix the legacy `"note"` mapping.
- `Shared/Database/NoteRecord.swift` — add `var epubBlockID: String?` + coding key.
- `Shared/Database/DAOs/NoteDAO.swift` — add `notes(withEpubBlockIDsIn:audiobookID:)` positional query + an `epub_block_id`-aware insert path (already covered by the existing `insert` since it persists the struct).
- `EchoCore/Models/ReaderCardItem.swift` — add `.note(NoteRecord)` / `.voiceMemo(VoiceMemoRecord)` cases; extend `id`, `==`, `hash(into:)`.
- `EchoCore/Views/ReaderFeedCollectionView.swift` — register the two new cells in `makeUIView`; add two `case` branches to `cell(for:at:collectionView:)`; route memo-play taps.
- `EchoCore/ViewModels/ReaderFeedViewModel.swift` — load notes/memos in `reload()`, call `FeedItemInjector` to thread them into `parsedSections`; expose `addNote(text:atBlockID:)` and `addVoiceMemo(fileURL:duration:atBlockID:)`; refresh on insert.
- `EchoCore/Views/ReaderTab.swift` — present `FeedCaptureBar`; wire its callbacks to the VM.

**Responsibility boundaries**

- `FeedItemInjector` — *shape only* (where each note/memo row sits relative to blocks). Pure; depends on `ReaderCardSection`/`ReaderCardItem`/`NoteRecord`/`VoiceMemoRecord`, not UIKit or DB.
- `VoiceMemoDAO` / `NoteDAO` — *persistence only* (`struct X { let db: DatabaseWriter }`).
- `VoiceMemoRecorder` — *device only* (AVAudioRecorder session, file lifecycle).
- `ReaderFeedViewModel` — *state + DB*: loads rows, calls the injector, owns capture entry points.
- `ReaderFeedCollectionView` — *rendering*: turns the new `ReaderCardItem` cases into cells, routes memo-play taps back.

---

## Reference: load-bearing facts verified in the code

- `ReaderCardItem` (`EchoCore/Models/ReaderCardItem.swift:13`) is a plain `enum` with `case chapterHeader(title:chapterIndex:)` and `case block(EPubBlockRecord)`; `id` is a `switch` (`"ch-\(chapterIndex)"`, `"b-\(block.id)"`); `Hashable` is **manual** — `==` (`:31`) and `hash(into:)` (`:42`) each `switch` over the cases with `hasher.combine(0)`/`combine(1)` discriminators; `Sendable` is declared empty (`:55`). New cases must add a discriminator (use `2` and `3`) and branches in all three.
- `ReaderCardSection` (`…/ReaderCardItem.swift:5`): `let id`, `let headingStack: [String]`, `let items: [ReaderCardItem]`. Holds `[ReaderCardItem]` heterogeneously — no change needed.
- `TimelineItemType` (`Shared/Database/TimelineItem.swift:5`) is a `String`-raw `enum` with 5 cases. The legacy initializer `init?(legacyRawValue:)` (`…:158`) maps `"note"` → `.bookmark` (`…:165`). When `.note` becomes a real case, that line must change to `self = .note`, otherwise the new case is shadowed by the bookmark migration path. `.voiceMemo` has no legacy alias.
- `NoteRecord` (`Shared/Database/NoteRecord.swift:5`): `Codable, FetchableRecord, MutablePersistableRecord`; fields `id, audiobookID, text, mediaTimestamp, realTimestamp, isEnabled, playlistPosition, createdAt, modifiedAt`; `databaseTableName = "note"`. **No `epub_block_id`.** The `note` table itself is created in `Shared/Database/Schema_V2.swift:9` and altered in `Schema_V14.swift:32` (`is_global`, `voice_memo_path`) — those two columns are NOT in the `NoteRecord` struct today (the struct under-declares the table; that is fine for GRDB row decoding because `FetchableRecord` only reads the keys it knows). Add only `epub_block_id` to the struct.
- `NoteDAO` (`Shared/Database/DAOs/NoteDAO.swift:5`) is `struct NoteDAO { let db: DatabaseWriter }` with `notes(for:)`, `notes(in:audiobookID:)`, `note(id:)`, `insert(_:)`, `update(_:)`, `delete(id:)`, `deleteAll(for:)`, `count(for:)`. `insert` persists the whole struct, so adding `epubBlockID` to the struct makes it persist automatically once the column exists.
- `BookmarkRecord` (`Shared/Database/BookmarkRecord.swift:8`) already has `var voiceMemoPath: String?` (`:14`) — this is the *attachment* path on a bookmark. Phase 4's standalone memo is a different table; do not conflate.
- `ChapterDividerCell` (`EchoCore/Views/ReaderFeedCollectionView.swift:605`) is the cell template to copy for the two new cells: `private final class … : UICollectionViewCell`, `static let reuseIdentifier`, a `UILabel` with autolayout in `init(frame:)`, `required init?(coder:) { fatalError(…) }`, and a `configure(with:)`.
- Cell registration is in `makeUIView` (search `ReaderFeedCollectionView.swift` for `collectionView.register(`): four `collectionView.register(Cell.self, forCellWithReuseIdentifier: Cell.reuseIdentifier)` calls. The dispatch is a manual `switch item { … }` in `cell(for:at:collectionView:)` (search for `func cell(for:`); `.chapterHeader` and `.block` branches are there. `didSelectItemAt` and the context-menu builder both pattern-match `case .block(let block)` — the new `.note`/`.voiceMemo` cases fall through harmlessly there (memo-play is its own button tap, not cell selection). **Note (post-Phase-1):** `didSelectItemAt` also matches `.chapterHeader` to toggle chapter collapse — the conclusion for `.note`/`.voiceMemo` still holds (they are not matched), but locate insertion points by function name after rebase, not line number.
- `ReaderFeedViewModel.reload()` (search `ReaderFeedViewModel.swift` for `func reload()`) builds `parsedSections` in document order from `blockDAO.blocksByChapter(for:)`; DAOs are built in `init` (`blockDAO`, `chapterDAO`, `db`). `@MainActor @Observable`. Phase 1 adds `rebuildDisplaySections()` and `displaySections` — locate these by name after rebase.
- Test conventions: Swift Testing `@Test`/`#expect`, `@MainActor @Suite struct`, `@testable import Echo`, `DatabaseService(inMemory: ())` then `db.read`/`db.write { db in … }` (and `db.writer` for DAO construction — see `SchemaV23Tests.swift`, `NoteDAO`). `EPubBlockRecord` has a synthesized memberwise initializer (no custom init) — use it for fixtures (`Shared/Database/EPubBlockRecord.swift:7`).
- Schema test template: `SchemaV23Tests.swift` — `@MainActor @Suite struct SchemaV23Tests`, builds `DatabaseService(inMemory: ())`, runs `PRAGMA table_info(<table>)`, `#expect(columns.contains("…"))`.

---

## Task 1: Schema migration — `note.epub_block_id` + `voice_memo` table

Notes need a document-order position (Trap 3): add `epub_block_id` so a note threads into the feed by block, mirroring `TimelineItem.epubBlockID`. Voice memos need a standalone home (Trap 4 default): a net-new `voice_memo` table holding the `.m4a` path. One migration does both.

**Files:**
- Create: `Shared/Database/Migrations/Schema_V24.swift`
- Modify: `Shared/Database/DatabaseService.swift`
- Test: `EchoTests/SchemaV24Tests.swift`

**Interfaces:**
- Produces: migration `"v24_feed_note_position_voice_memo"` → `Schema_V24.migrate(_:)`.
- DDL: `ALTER TABLE note ADD COLUMN epub_block_id TEXT`; `CREATE TABLE voice_memo(...)`; `CREATE INDEX idx_voice_memo_audiobook_time`.

- [ ] **Step 1: Confirm the next free migration version (do NOT skip)**

Run, in the foreground:

```bash
cd /Users/dfakkeldy/Developer/Echo && ls Shared/Database/Migrations/ | sort -V | tail -5 && grep -n 'registerMigration' Shared/Database/DatabaseService.swift | tail -3
```

Expected: highest file `Schema_V23.swift`, last registration `"v23_audiobook_abs_provenance"`. If a `Schema_V24.swift` already exists (a later phase claimed it), bump every `V24`/`v24_…` token in this task to `V25`/`v25_…` consistently. Proceed only after confirming the number is free.

- [ ] **Step 2: Write the failing schema test**

Create `EchoTests/SchemaV24Tests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct SchemaV24Tests {
    @Test func v24AddsEpubBlockIDColumnToNote() throws {
        let db = try DatabaseService(inMemory: ())
        let columns = Set(
            try db.read { db in
                try Row.fetchAll(db, sql: "PRAGMA table_info(note)").map {
                    $0["name"] as? String ?? ""
                }
            })
        #expect(columns.contains("epub_block_id"))
    }

    @Test func v24CreatesVoiceMemoTable() throws {
        let db = try DatabaseService(inMemory: ())
        let columns = Set(
            try db.read { db in
                try Row.fetchAll(db, sql: "PRAGMA table_info(voice_memo)").map {
                    $0["name"] as? String ?? ""
                }
            })
        #expect(columns.contains("id"))
        #expect(columns.contains("audiobook_id"))
        #expect(columns.contains("epub_block_id"))
        #expect(columns.contains("media_timestamp"))
        #expect(columns.contains("file_path"))
        #expect(columns.contains("duration"))
        #expect(columns.contains("is_enabled"))
        #expect(columns.contains("created_at"))
        #expect(columns.contains("modified_at"))
    }

    @Test func v24CreatesVoiceMemoIndex() throws {
        let db = try DatabaseService(inMemory: ())
        let indexNames = try db.read { db in
            try Row.fetchAll(db, sql: "PRAGMA index_list(voice_memo)").map {
                $0["name"] as? String ?? ""
            }
        }
        #expect(indexNames.contains("idx_voice_memo_audiobook_time"))
    }
}
```

- [ ] **Step 3: Create the migration**

Create `Shared/Database/Migrations/Schema_V24.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

/// V24 — Unified-feed Phase 4 content types.
///
/// 1. `note.epub_block_id` (nullable FK to `epub_block.id`) lets notes thread
///    into the reader feed at their EPUB document position, mirroring how
///    `timeline_item.epub_block_id` positions other items. Existing notes leave
///    it NULL and continue to be positioned by `media_timestamp` only.
/// 2. `voice_memo` is a net-new standalone-memo table (the file + a row). It is
///    distinct from `bookmark.voice_memo_path`, which remains an *attachment*
///    on a bookmark. A feed voice memo does not imply a bookmark.
enum Schema_V24 {
    nonisolated static func migrate(_ db: Database) throws {
        // 1. Document-order position for notes.
        try db.alter(table: "note") { t in
            t.add(column: "epub_block_id", .text)
        }

        // 2. Standalone voice memos.
        try db.create(table: "voice_memo", ifNotExists: true) { t in
            t.column("id", .text).primaryKey()
            t.column("audiobook_id", .text).notNull()
                .references("audiobook", onDelete: .cascade)
            t.column("epub_block_id", .text)
            t.column("media_timestamp", .double).notNull()
            t.column("file_path", .text).notNull()
            t.column("duration", .double)
            t.column("is_enabled", .boolean).notNull().defaults(to: true)
            t.column("created_at", .text).notNull().defaults(sql: "(datetime('now'))")
            t.column("modified_at", .text).notNull().defaults(sql: "(datetime('now'))")
        }

        try db.create(
            index: "idx_voice_memo_audiobook_time",
            on: "voice_memo",
            columns: ["audiobook_id", "media_timestamp"],
            ifNotExists: true
        )
    }
}
```

- [ ] **Step 4: Register the migration**

In `Shared/Database/DatabaseService.swift`, after the `v23_audiobook_abs_provenance` block (`:115`–`:117`), add:

```swift
        migrator.registerMigration("v23_audiobook_abs_provenance") { db in
            try Schema_V23.migrate(db)
        }
        migrator.registerMigration("v24_feed_note_position_voice_memo") { db in
            try Schema_V24.migrate(db)
        }
        try migrator.migrate(writer)
```

(The first `registerMigration` line above already exists — only the `v24_…` block and the existing `try migrator.migrate(writer)` follow it. Do not duplicate `try migrator.migrate(writer)`.)

- [ ] **Step 5: CloudKit safety check (Trap 7)**

Run, in the foreground:

```bash
cd /Users/dfakkeldy/Developer/Echo && grep -rIn 'CKRecord\|recordType\|CloudKit' Shared/ EchoCore/ | grep -i 'note\|voice_memo\|voiceMemo' || echo "NO CloudKit mapping touches note/voice_memo — safe to add columns"
```

Expected: the `echo` fallback prints (no CloudKit record type references `note`/`voice_memo`). If any line is printed instead, STOP and add the new column to that CloudKit record type before continuing; note the finding in the PR body.

- [ ] **Step 6: Build the test target and run the schema test**

```bash
cd /Users/dfakkeldy/Developer/Echo && make build-tests && make test-only FILTER=EchoTests/SchemaV24Tests
```

Expected output ends with `Test Suite 'SchemaV24Tests' passed` (or the Swift Testing equivalent `✔ Suite SchemaV24Tests passed`) and all 3 tests green.

- [ ] **Step 7: Run schema-migration-reviewer**

Dispatch the `schema-migration-reviewer` agent on `Shared/Database/Migrations/Schema_V24.swift` + `DatabaseService.swift`. Address any blocking finding (version collision, missing `ifNotExists`, FK cascade correctness). Re-run Step 6 if you change the migration.

- [ ] **Step 8: Commit**

```bash
cd /Users/dfakkeldy/Developer/Echo
git add Shared/Database/Migrations/Schema_V24.swift Shared/Database/DatabaseService.swift EchoTests/SchemaV24Tests.swift
git commit -m "feat(db): V24 — note.epub_block_id + standalone voice_memo table (unified feed Phase 4)"
```

---

## Task 2: `VoiceMemoRecord` + `VoiceMemoDAO`

GRDB record and DAO for the new table, including a positional query (memos in a set of block IDs) for feed injection and a time-range query for fallback positioning.

**Files:**
- Create: `Shared/Database/VoiceMemoRecord.swift`
- Create: `Shared/Database/DAOs/VoiceMemoDAO.swift`
- Test: `EchoTests/VoiceMemoDAOTests.swift`

**Interfaces:**
- Produces: `struct VoiceMemoRecord` (fields below); `struct VoiceMemoDAO { let db: DatabaseWriter }` with `memos(for:)`, `memos(withEpubBlockIDsIn:audiobookID:)`, `memo(id:)`, `insert(_:)`, `delete(id:)`.

- [ ] **Step 1: Write the failing DAO test**

Create `EchoTests/VoiceMemoDAOTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct VoiceMemoDAOTests {
    /// Inserts an audiobook row so the `voice_memo.audiobook_id` FK is satisfiable.
    private func seed(_ db: DatabaseService) throws {
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title) VALUES (?, ?)",
                arguments: ["bk1", "Test Book"])
        }
    }

    @Test func insertThenFetchByAudiobook() throws {
        let service = try DatabaseService(inMemory: ())
        try seed(service)
        let dao = VoiceMemoDAO(db: service.writer)

        let memo = VoiceMemoRecord(
            id: "vm1", audiobookID: "bk1", epubBlockID: "blk-5",
            mediaTimestamp: 42.0, filePath: "memos/vm1.m4a", duration: 3.2,
            isEnabled: true, createdAt: "2026-06-22T00:00:00Z",
            modifiedAt: "2026-06-22T00:00:00Z")
        try dao.insert(memo)

        let fetched = try dao.memos(for: "bk1")
        #expect(fetched.count == 1)
        #expect(fetched.first?.id == "vm1")
        #expect(fetched.first?.epubBlockID == "blk-5")
        #expect(fetched.first?.filePath == "memos/vm1.m4a")
    }

    @Test func fetchByEpubBlockIDsFiltersToRequestedBlocks() throws {
        let service = try DatabaseService(inMemory: ())
        try seed(service)
        let dao = VoiceMemoDAO(db: service.writer)

        try dao.insert(VoiceMemoRecord(
            id: "vmA", audiobookID: "bk1", epubBlockID: "blk-1",
            mediaTimestamp: 1, filePath: "a.m4a", duration: nil,
            isEnabled: true, createdAt: "t", modifiedAt: "t"))
        try dao.insert(VoiceMemoRecord(
            id: "vmB", audiobookID: "bk1", epubBlockID: "blk-2",
            mediaTimestamp: 2, filePath: "b.m4a", duration: nil,
            isEnabled: true, createdAt: "t", modifiedAt: "t"))

        let onlyB = try dao.memos(withEpubBlockIDsIn: ["blk-2"], audiobookID: "bk1")
        #expect(onlyB.map(\.id) == ["vmB"])
    }

    @Test func deleteRemovesRow() throws {
        let service = try DatabaseService(inMemory: ())
        try seed(service)
        let dao = VoiceMemoDAO(db: service.writer)
        try dao.insert(VoiceMemoRecord(
            id: "vm1", audiobookID: "bk1", epubBlockID: nil,
            mediaTimestamp: 0, filePath: "x.m4a", duration: nil,
            isEnabled: true, createdAt: "t", modifiedAt: "t"))
        try dao.delete(id: "vm1")
        #expect(try dao.memos(for: "bk1").isEmpty)
    }
}
```

- [ ] **Step 2: Create the record**

Create `Shared/Database/VoiceMemoRecord.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

/// GRDB record for the `voice_memo` table (V24). A standalone voice memo: an
/// `.m4a` file (`file_path`, relative to the book folder) plus this row. Distinct
/// from `bookmark.voice_memo_path`, which is an attachment on a bookmark.
struct VoiceMemoRecord: Codable, FetchableRecord, MutablePersistableRecord, Equatable, Sendable {
    var id: String
    var audiobookID: String
    /// FK to `epub_block.id` for document-order feed positioning; nil → positioned
    /// by `mediaTimestamp` only.
    var epubBlockID: String?
    var mediaTimestamp: TimeInterval
    var filePath: String
    var duration: TimeInterval?
    var isEnabled: Bool
    var createdAt: String
    var modifiedAt: String

    static let databaseTableName = "voice_memo"

    enum CodingKeys: String, CodingKey {
        case id
        case audiobookID = "audiobook_id"
        case epubBlockID = "epub_block_id"
        case mediaTimestamp = "media_timestamp"
        case filePath = "file_path"
        case duration
        case isEnabled = "is_enabled"
        case createdAt = "created_at"
        case modifiedAt = "modified_at"
    }
}
```

- [ ] **Step 3: Create the DAO**

Create `Shared/Database/DAOs/VoiceMemoDAO.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

struct VoiceMemoDAO {
    let db: DatabaseWriter

    func memos(for audiobookID: String) throws -> [VoiceMemoRecord] {
        try db.read { db in
            try VoiceMemoRecord
                .filter(Column("audiobook_id") == audiobookID)
                .order(Column("media_timestamp"), Column("created_at"))
                .fetchAll(db)
        }
    }

    /// Memos whose `epub_block_id` is one of `blockIDs`, for feed injection.
    /// Note: the VM feeds `FeedItemInjector` via `memos(for:)` + in-memory
    /// grouping; this query is tested and available for future callers (e.g.
    /// per-chapter loading), but is not called in the current shipping path.
    func memos(withEpubBlockIDsIn blockIDs: [String], audiobookID: String) throws
        -> [VoiceMemoRecord]
    {
        guard !blockIDs.isEmpty else { return [] }
        return try db.read { db in
            try VoiceMemoRecord
                .filter(Column("audiobook_id") == audiobookID)
                .filter(blockIDs.contains(Column("epub_block_id")))
                .order(Column("media_timestamp"), Column("created_at"))
                .fetchAll(db)
        }
    }

    func memo(id: String) throws -> VoiceMemoRecord? {
        try db.read { db in try VoiceMemoRecord.fetchOne(db, key: id) }
    }

    func insert(_ memo: VoiceMemoRecord) throws {
        var copy = memo
        try db.write { db in try copy.insert(db) }
    }

    func delete(id: String) throws {
        _ = try db.write { db in try VoiceMemoRecord.deleteOne(db, key: id) }
    }
}
```

- [ ] **Step 4: Build and run the test**

```bash
cd /Users/dfakkeldy/Developer/Echo && make build-tests && make test-only FILTER=EchoTests/VoiceMemoDAOTests
```

Expected: `VoiceMemoDAOTests` passes, all 3 tests green.

- [ ] **Step 5: Commit**

```bash
cd /Users/dfakkeldy/Developer/Echo
git add Shared/Database/VoiceMemoRecord.swift Shared/Database/DAOs/VoiceMemoDAO.swift EchoTests/VoiceMemoDAOTests.swift
git commit -m "feat(db): VoiceMemoRecord + VoiceMemoDAO (unified feed Phase 4)"
```

---

## Task 3: Extend `NoteRecord` + `NoteDAO` with `epub_block_id`

Add the field to the struct so it persists, and a positional query mirroring `VoiceMemoDAO.memos(withEpubBlockIDsIn:…)`.

**Files:**
- Modify: `Shared/Database/NoteRecord.swift`
- Modify: `Shared/Database/DAOs/NoteDAO.swift`
- Test: `EchoTests/NoteDAOEpubBlockTests.swift`

**Interfaces:**
- Produces: `NoteRecord.epubBlockID: String?`; `NoteDAO.notes(withEpubBlockIDsIn:audiobookID:)`.

- [ ] **Step 1: Write the failing test**

Create `EchoTests/NoteDAOEpubBlockTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct NoteDAOEpubBlockTests {
    private func seed(_ db: DatabaseService) throws {
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title) VALUES (?, ?)",
                arguments: ["bk1", "Test Book"])
        }
    }

    @Test func insertedNotePersistsEpubBlockID() throws {
        let service = try DatabaseService(inMemory: ())
        try seed(service)
        let dao = NoteDAO(db: service.writer)

        let note = NoteRecord(
            id: "n1", audiobookID: "bk1", text: "hello",
            mediaTimestamp: 5.0, realTimestamp: nil, isEnabled: true,
            playlistPosition: nil, createdAt: "t", modifiedAt: "t",
            epubBlockID: "blk-3")
        try dao.insert(note)

        let fetched = try dao.note(id: "n1")
        #expect(fetched?.epubBlockID == "blk-3")
    }

    @Test func notesByEpubBlockIDsFiltersToRequestedBlocks() throws {
        let service = try DatabaseService(inMemory: ())
        try seed(service)
        let dao = NoteDAO(db: service.writer)

        try dao.insert(NoteRecord(
            id: "nA", audiobookID: "bk1", text: "a", mediaTimestamp: 1,
            realTimestamp: nil, isEnabled: true, playlistPosition: nil,
            createdAt: "t", modifiedAt: "t", epubBlockID: "blk-1"))
        try dao.insert(NoteRecord(
            id: "nB", audiobookID: "bk1", text: "b", mediaTimestamp: 2,
            realTimestamp: nil, isEnabled: true, playlistPosition: nil,
            createdAt: "t", modifiedAt: "t", epubBlockID: "blk-2"))

        let onlyB = try dao.notes(withEpubBlockIDsIn: ["blk-2"], audiobookID: "bk1")
        #expect(onlyB.map(\.id) == ["nB"])
    }
}
```

- [ ] **Step 2: Add `epubBlockID` to `NoteRecord`**

In `Shared/Database/NoteRecord.swift`, add the stored property after `modifiedAt` and its coding key after `modifiedAt`:

```swift
struct NoteRecord: Codable, FetchableRecord, MutablePersistableRecord {
    var id: String
    var audiobookID: String
    var text: String
    var mediaTimestamp: TimeInterval
    var realTimestamp: String?
    var isEnabled: Bool
    var playlistPosition: Double?
    var createdAt: String
    var modifiedAt: String
    /// FK to `epub_block.id` (V24) for document-order feed positioning; nil →
    /// positioned by `mediaTimestamp` only (legacy notes).
    var epubBlockID: String?

    static let databaseTableName = "note"

    enum CodingKeys: String, CodingKey {
        case id
        case audiobookID = "audiobook_id"
        case text
        case mediaTimestamp = "media_timestamp"
        case realTimestamp = "real_timestamp"
        case isEnabled = "is_enabled"
        case playlistPosition = "playlist_position"
        case createdAt = "created_at"
        case modifiedAt = "modified_at"
        case epubBlockID = "epub_block_id"
    }
}
```

> Note: this is the memberwise-init shape the tests rely on (`epubBlockID` is the **last** parameter). Existing call sites that construct `NoteRecord` without `epubBlockID` will fail to compile — Swift's synthesized memberwise init has no default for it. To keep existing callers source-compatible, add a default: change the line to `var epubBlockID: String? = nil`. The tests above pass `epubBlockID:` explicitly either way; the default is what protects unrelated callers. **Use `var epubBlockID: String? = nil`.**

- [ ] **Step 3: Add the positional query to `NoteDAO`**

In `Shared/Database/DAOs/NoteDAO.swift`, add after `notes(in:audiobookID:)` (`:25`):

```swift
    /// Notes whose `epub_block_id` is one of `blockIDs`, for feed injection.
    /// Note: the VM feeds `FeedItemInjector` via `notes(for:)` + in-memory
    /// grouping; this query is tested and available for future callers (e.g.
    /// per-chapter loading), but is not called in the current shipping path.
    func notes(withEpubBlockIDsIn blockIDs: [String], audiobookID: String) throws
        -> [NoteRecord]
    {
        guard !blockIDs.isEmpty else { return [] }
        return try db.read { db in
            try NoteRecord
                .filter(Column("audiobook_id") == audiobookID)
                .filter(blockIDs.contains(Column("epub_block_id")))
                .order(Column("media_timestamp"), Column("created_at"))
                .fetchAll(db)
        }
    }
```

- [ ] **Step 4: Build and run**

```bash
cd /Users/dfakkeldy/Developer/Echo && make build-tests && make test-only FILTER=EchoTests/NoteDAOEpubBlockTests
```

Expected: `NoteDAOEpubBlockTests` passes, both tests green. (If `make build-tests` surfaces a pre-existing `NoteRecord(…)` call site that now needs the default, the `= nil` from Step 2 fixes it — confirm no call site passes positional args past `modifiedAt`.)

- [ ] **Step 5: Commit**

```bash
cd /Users/dfakkeldy/Developer/Echo
git add Shared/Database/NoteRecord.swift Shared/Database/DAOs/NoteDAO.swift EchoTests/NoteDAOEpubBlockTests.swift
git commit -m "feat(db): NoteRecord.epubBlockID + positional NoteDAO query (unified feed Phase 4)"
```

---

## Task 4: `TimelineItemType` — add `.voiceMemo` and `.note`

Add the two persisted item-type tags and fix the legacy `"note"` mapping so it no longer aliases to `.bookmark` (Trap / recon item 9).

**Files:**
- Modify: `Shared/Database/TimelineItem.swift`
- Test: `EchoTests/TimelineItemTypePhase4Tests.swift`

**Interfaces:**
- Produces: `TimelineItemType.voiceMemo` (raw `"voiceMemo"`), `TimelineItemType.note` (raw `"note"`); `init?(legacyRawValue: "note")` now → `.note`.

- [ ] **Step 1: Write the failing test**

Create `EchoTests/TimelineItemTypePhase4Tests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct TimelineItemTypePhase4Tests {
    @Test func newCasesHaveStableRawValues() {
        #expect(TimelineItemType.voiceMemo.rawValue == "voiceMemo")
        #expect(TimelineItemType.note.rawValue == "note")
    }

    @Test func roundTripsThroughRawValue() {
        #expect(TimelineItemType(rawValue: "voiceMemo") == .voiceMemo)
        #expect(TimelineItemType(rawValue: "note") == .note)
    }

    @Test func legacyNoteMapsToNoteNotBookmark() {
        #expect(TimelineItemType(legacyRawValue: "note") == .note)
    }

    @Test func legacyBookmarkStillMapsToBookmark() {
        #expect(TimelineItemType(legacyRawValue: "bookmark") == .bookmark)
    }
}
```

- [ ] **Step 2: Add the enum cases**

In `Shared/Database/TimelineItem.swift`, replace the enum (`:5`–`:11`):

```swift
enum TimelineItemType: String, Codable {
    case textSegment
    case chapterMarker
    case imageAsset
    case bookmark
    case ankiCard
    case voiceMemo
    case note
}
```

- [ ] **Step 3: Confirm `legacyRawValue` is read-only before changing it**

Run:
```bash
cd /Users/dfakkeldy/Developer/Echo && grep -rn 'legacyRawValue' Shared/ EchoCore/ --include='*.swift'
```
Expected: only `TimelineItem.swift` defines and uses `init?(legacyRawValue:)` — no code *writes* new rows with the old `"note"` string (the migrator only reads persisted rows). If any call site passes `"note"` *to* `legacyRawValue` to create new data, stop and investigate before proceeding; the remap is safe only if the path is purely read (de-serialization of old DB rows).

- [ ] **Step 4: Fix the legacy mapping**

In the same file, change the `"note"` branch of `init?(legacyRawValue:)` (locate by searching for `case "note":` inside `init?(legacyRawValue:)`) from `case "note": self = .bookmark` to:

```swift
        case "note": self = .note
```

- [ ] **Step 6: Build and run**

```bash
cd /Users/dfakkeldy/Developer/Echo && make build-tests && make test-only FILTER=EchoTests/TimelineItemTypePhase4Tests
```

Expected: `TimelineItemTypePhase4Tests` passes, all 4 tests green.

- [ ] **Step 7: Commit**

```bash
cd /Users/dfakkeldy/Developer/Echo
git add Shared/Database/TimelineItem.swift EchoTests/TimelineItemTypePhase4Tests.swift
git commit -m "feat(feed): TimelineItemType .voiceMemo + .note; legacy note→note (unified feed Phase 4)"
```

---

## Task 5: `ReaderCardItem` — add `.note` and `.voiceMemo` cases

Add the two feed-row cases with unique `id` prefixes (`"note-"`, `"vm-"`) and extend the manual `Equatable`/`Hashable` (Trap 1 — duplicate ids crash `NSDiffableDataSourceSnapshot.appendItems`).

**Files:**
- Modify: `EchoCore/Models/ReaderCardItem.swift`
- Test: `EchoTests/ReaderCardItemPhase4Tests.swift`

**Interfaces:**
- Produces: `ReaderCardItem.note(NoteRecord)` with `id == "note-\(note.id)"`; `ReaderCardItem.voiceMemo(VoiceMemoRecord)` with `id == "vm-\(memo.id)"`.

- [ ] **Step 1: Write the failing test**

Create `EchoTests/ReaderCardItemPhase4Tests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct ReaderCardItemPhase4Tests {
    private func makeNote(_ id: String) -> NoteRecord {
        NoteRecord(
            id: id, audiobookID: "bk1", text: "n", mediaTimestamp: 0,
            realTimestamp: nil, isEnabled: true, playlistPosition: nil,
            createdAt: "t", modifiedAt: "t", epubBlockID: "blk-1")
    }

    private func makeMemo(_ id: String) -> VoiceMemoRecord {
        VoiceMemoRecord(
            id: id, audiobookID: "bk1", epubBlockID: "blk-1",
            mediaTimestamp: 0, filePath: "x.m4a", duration: nil,
            isEnabled: true, createdAt: "t", modifiedAt: "t")
    }

    @Test func noteAndMemoHaveDistinctPrefixedIDs() {
        let note = ReaderCardItem.note(makeNote("abc"))
        let memo = ReaderCardItem.voiceMemo(makeMemo("abc"))
        #expect(note.id == "note-abc")
        #expect(memo.id == "vm-abc")
        // Same underlying id, different prefixes → no snapshot collision.
        #expect(note.id != memo.id)
    }

    @Test func equalityIsCaseAndPayloadSensitive() {
        let a = ReaderCardItem.note(makeNote("1"))
        let b = ReaderCardItem.note(makeNote("1"))
        let c = ReaderCardItem.note(makeNote("2"))
        #expect(a == b)
        #expect(a != c)
        #expect(a != ReaderCardItem.voiceMemo(makeMemo("1")))
    }

    @Test func hashMatchesEquality() {
        let a = ReaderCardItem.voiceMemo(makeMemo("1"))
        let b = ReaderCardItem.voiceMemo(makeMemo("1"))
        #expect(a.hashValue == b.hashValue)
    }
}
```

- [ ] **Step 2: Add the cases and extend `id`**

In `EchoCore/Models/ReaderCardItem.swift`, replace the enum body (`:13`–`:28`):

```swift
/// Items displayed in the EPUB reader feed.
enum ReaderCardItem {
    /// A divider between chapters showing the chapter title.
    case chapterHeader(title: String, chapterIndex: Int)
    /// An EPUB block (heading, paragraph, or image).
    case block(EPubBlockRecord)
    /// A free-text note threaded into the feed at its EPUB block position.
    case note(NoteRecord)
    /// A standalone voice memo threaded into the feed at its EPUB block position.
    case voiceMemo(VoiceMemoRecord)
    // Future: case flashcard(Flashcard, associatedBlockIDs: [String], placement: FlashcardPlacement)

    var id: String {
        switch self {
        case .chapterHeader(_, let chapterIndex):
            return "ch-\(chapterIndex)"
        case .block(let block):
            return "b-\(block.id)"
        case .note(let note):
            return "note-\(note.id)"
        case .voiceMemo(let memo):
            return "vm-\(memo.id)"
        }
    }
}
```

- [ ] **Step 3: Extend `==` and `hash(into:)`**

In the same file, replace the `Hashable` extension (`:30`–`:53`):

```swift
extension ReaderCardItem: Hashable {
    nonisolated static func == (lhs: ReaderCardItem, rhs: ReaderCardItem) -> Bool {
        switch (lhs, rhs) {
        case let (.chapterHeader(a1, a2), .chapterHeader(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.block(a), .block(b)):
            return a == b
        case let (.note(a), .note(b)):
            return a == b
        case let (.voiceMemo(a), .voiceMemo(b)):
            return a == b
        default:
            return false
        }
    }

    nonisolated func hash(into hasher: inout Hasher) {
        switch self {
        case .chapterHeader(let title, let chapterIndex):
            hasher.combine(0)
            hasher.combine(title)
            hasher.combine(chapterIndex)
        case .block(let block):
            hasher.combine(1)
            hasher.combine(block)
        case .note(let note):
            hasher.combine(2)
            hasher.combine(note)
        case .voiceMemo(let memo):
            hasher.combine(3)
            hasher.combine(memo)
        }
    }
}
```

> `NoteRecord` must be `Hashable`/`Equatable` for `hasher.combine(note)`. `NoteRecord` is `Codable` (auto-synthesizes `Equatable`/`Hashable` only if declared). Add the conformances explicitly: in `Shared/Database/NoteRecord.swift`, change `struct NoteRecord: Codable, FetchableRecord, MutablePersistableRecord {` to `struct NoteRecord: Codable, Equatable, Hashable, FetchableRecord, MutablePersistableRecord {`. `VoiceMemoRecord` already declares `Equatable, Sendable` (Task 2) — add `Hashable` to it too: change its declaration to `struct VoiceMemoRecord: Codable, FetchableRecord, MutablePersistableRecord, Equatable, Hashable, Sendable {`.

- [ ] **Step 4: Build and run**

```bash
cd /Users/dfakkeldy/Developer/Echo && make build-tests && make test-only FILTER=EchoTests/ReaderCardItemPhase4Tests
```

Expected: `ReaderCardItemPhase4Tests` passes, all 3 tests green.

- [ ] **Step 5: Commit**

```bash
cd /Users/dfakkeldy/Developer/Echo
git add EchoCore/Models/ReaderCardItem.swift Shared/Database/NoteRecord.swift Shared/Database/VoiceMemoRecord.swift EchoTests/ReaderCardItemPhase4Tests.swift
git commit -m "feat(feed): ReaderCardItem .note + .voiceMemo cases with unique ids (unified feed Phase 4)"
```

---

## Task 6: `FeedItemInjector` — pure positioning of notes/memos into sections

Pure math (no UIKit/DB) that takes the existing `[ReaderCardSection]` plus the loaded notes/memos and returns new sections with each note/memo `ReaderCardItem` inserted **immediately after** its anchor block. Notes/memos with no matching block in the section are dropped from injection (they remain reachable via other surfaces; the feed only shows positioned items). This mirrors the Phase 2 bookmark/card injection pattern.

**Files:**
- Create: `Shared/Feed/FeedItemInjector.swift`
- Test: `EchoTests/FeedItemInjectorTests.swift`

**Interfaces:**
- Consumes: `[ReaderCardSection]`, `notesByBlockID: [String: [NoteRecord]]`, `memosByBlockID: [String: [VoiceMemoRecord]]`.
- Produces: `static func inject(into sections: [ReaderCardSection], notesByBlockID:memosByBlockID:) -> [ReaderCardSection]`.

- [ ] **Step 1: Write the failing test**

Create `EchoTests/FeedItemInjectorTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct FeedItemInjectorTests {
    private func block(_ id: String) -> EPubBlockRecord {
        EPubBlockRecord(
            id: id, audiobookID: "bk1", spineHref: "c.xhtml", spineIndex: 0,
            blockIndex: 0, sequenceIndex: 0, blockKind: "paragraph",
            text: "t", htmlContent: nil, cardColor: nil, chapterThemeColor: nil,
            imagePath: nil, chapterIndex: 0, isHidden: false, hiddenReason: nil,
            wordCount: nil, markers: nil, textFormats: nil,
            createdAt: nil, modifiedAt: nil)
    }

    private func note(_ id: String, block blockID: String) -> NoteRecord {
        NoteRecord(
            id: id, audiobookID: "bk1", text: "n", mediaTimestamp: 0,
            realTimestamp: nil, isEnabled: true, playlistPosition: nil,
            createdAt: "t", modifiedAt: "t", epubBlockID: blockID)
    }

    private func memo(_ id: String, block blockID: String) -> VoiceMemoRecord {
        VoiceMemoRecord(
            id: id, audiobookID: "bk1", epubBlockID: blockID,
            mediaTimestamp: 0, filePath: "x.m4a", duration: nil,
            isEnabled: true, createdAt: "t", modifiedAt: "t")
    }

    @Test func noteIsInsertedRightAfterItsBlock() {
        let section = ReaderCardSection(
            id: "ch0-s0", headingStack: ["Chapter 1"],
            items: [.block(block("b1")), .block(block("b2"))])
        let result = FeedItemInjector.inject(
            into: [section],
            notesByBlockID: ["b1": [note("n1", block: "b1")]],
            memosByBlockID: [:])
        #expect(result.first?.items.map(\.id) == ["b-b1", "note-n1", "b-b2"])
    }

    @Test func memoFollowsNoteWhenBothAnchorSameBlock() {
        let section = ReaderCardSection(
            id: "ch0-s0", headingStack: [],
            items: [.block(block("b1"))])
        let result = FeedItemInjector.inject(
            into: [section],
            notesByBlockID: ["b1": [note("n1", block: "b1")]],
            memosByBlockID: ["b1": [memo("m1", block: "b1")]])
        #expect(result.first?.items.map(\.id) == ["b-b1", "note-n1", "vm-m1"])
    }

    @Test func unanchoredItemsAreDropped() {
        let section = ReaderCardSection(
            id: "ch0-s0", headingStack: [],
            items: [.block(block("b1"))])
        let result = FeedItemInjector.inject(
            into: [section],
            notesByBlockID: ["bX": [note("n1", block: "bX")]],
            memosByBlockID: [:])
        #expect(result.first?.items.map(\.id) == ["b-b1"])
    }

    @Test func headerOnlySectionIsUnchanged() {
        let section = ReaderCardSection(
            id: "ch0-s0", headingStack: ["Chapter 1"],
            items: [.chapterHeader(title: "Chapter 1", chapterIndex: 0)])
        let result = FeedItemInjector.inject(
            into: [section], notesByBlockID: [:], memosByBlockID: [:])
        #expect(result.first?.items.map(\.id) == ["ch-0"])
    }
}
```

- [ ] **Step 2: Create the injector**

Create `Shared/Feed/FeedItemInjector.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Pure positioning: threads note/voice-memo feed items into existing reader
/// sections at their anchor block's document position. No UIKit, no DB — so the
/// macOS target can reuse it later. Mirrors the Phase 2 bookmark/card injection.
enum FeedItemInjector {
    /// Returns new sections with each note/memo inserted immediately after the
    /// `.block` whose id matches its `epubBlockID`. When several items anchor the
    /// same block, notes precede memos, each group ordered as supplied. Items
    /// with no matching block in any section are dropped (not surfaced in-feed).
    static func inject(
        into sections: [ReaderCardSection],
        notesByBlockID: [String: [NoteRecord]],
        memosByBlockID: [String: [VoiceMemoRecord]]
    ) -> [ReaderCardSection] {
        sections.map { section in
            var newItems: [ReaderCardItem] = []
            newItems.reserveCapacity(section.items.count)
            for item in section.items {
                newItems.append(item)
                guard case .block(let block) = item else { continue }
                if let notes = notesByBlockID[block.id] {
                    for note in notes { newItems.append(.note(note)) }
                }
                if let memos = memosByBlockID[block.id] {
                    for memo in memos { newItems.append(.voiceMemo(memo)) }
                }
            }
            return ReaderCardSection(
                id: section.id, headingStack: section.headingStack, items: newItems)
        }
    }
}
```

- [ ] **Step 3: Build and run**

```bash
cd /Users/dfakkeldy/Developer/Echo && make build-tests && make test-only FILTER=EchoTests/FeedItemInjectorTests
```

Expected: `FeedItemInjectorTests` passes, all 4 tests green.

- [ ] **Step 4: Commit**

```bash
cd /Users/dfakkeldy/Developer/Echo
git add Shared/Feed/FeedItemInjector.swift EchoTests/FeedItemInjectorTests.swift
git commit -m "feat(feed): FeedItemInjector — pure note/memo positioning (unified feed Phase 4)"
```

---

## Task 7: Feed cells for note and voice-memo rows

Two `UICollectionViewCell` subclasses modeled on `ChapterDividerCell` (`ReaderFeedCollectionView.swift:605`). The memo cell exposes a play button via a callback so a tap plays the `.m4a` without triggering cell selection.

**Files:**
- Create: `EchoCore/Views/NoteFeedCell.swift`
- Create: `EchoCore/Views/VoiceMemoFeedCell.swift`

**Interfaces:**
- Produces: `final class NoteFeedCell: UICollectionViewCell` with `reuseIdentifier`, `configure(text:)`. `final class VoiceMemoFeedCell: UICollectionViewCell` with `reuseIdentifier`, `configure(durationText:onPlay:)`.

- [ ] **Step 1: Create `NoteFeedCell`**

Create `EchoCore/Views/NoteFeedCell.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import UIKit

/// Feed row for a free-text note threaded at its EPUB block position.
final class NoteFeedCell: UICollectionViewCell {
    static let reuseIdentifier = "NoteFeedCell"

    private let container: UIView = {
        let v = UIView()
        v.backgroundColor = .secondarySystemBackground
        v.layer.cornerRadius = 12
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let iconView: UIImageView = {
        let iv = UIImageView(image: UIImage(systemName: "note.text"))
        iv.tintColor = .systemYellow
        iv.contentMode = .scaleAspectFit
        iv.setContentHuggingPriority(.required, for: .horizontal)
        iv.translatesAutoresizingMaskIntoConstraints = false
        return iv
    }()

    private let label: UILabel = {
        let l = UILabel()
        l.font = .preferredFont(forTextStyle: .callout)
        l.textColor = .label
        l.numberOfLines = 0
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(container)
        container.addSubview(iconView)
        container.addSubview(label)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            container.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            container.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            container.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),

            iconView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            iconView.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),

            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func configure(text: String) {
        label.text = text
    }
}
```

- [ ] **Step 2: Create `VoiceMemoFeedCell`**

Create `EchoCore/Views/VoiceMemoFeedCell.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import UIKit

/// Feed row for a standalone voice memo. The play button fires `onPlay` so a tap
/// plays the audio without triggering collection-view cell selection.
final class VoiceMemoFeedCell: UICollectionViewCell {
    static let reuseIdentifier = "VoiceMemoFeedCell"

    private var onPlay: (() -> Void)?

    private let container: UIView = {
        let v = UIView()
        v.backgroundColor = .secondarySystemBackground
        v.layer.cornerRadius = 12
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let playButton: UIButton = {
        let b = UIButton(type: .system)
        b.setImage(UIImage(systemName: "play.circle.fill"), for: .normal)
        b.tintColor = .systemBlue
        b.setContentHuggingPriority(.required, for: .horizontal)
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    private let label: UILabel = {
        let l = UILabel()
        l.font = .preferredFont(forTextStyle: .callout)
        l.textColor = .label
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.addSubview(container)
        container.addSubview(playButton)
        container.addSubview(label)
        playButton.addTarget(self, action: #selector(playTapped), for: .touchUpInside)
        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            container.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            container.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            container.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),

            playButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            playButton.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            playButton.widthAnchor.constraint(equalToConstant: 28),
            playButton.heightAnchor.constraint(equalToConstant: 28),

            label.leadingAnchor.constraint(equalTo: playButton.trailingAnchor, constant: 10),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func configure(durationText: String, onPlay: @escaping () -> Void) {
        label.text = durationText
        self.onPlay = onPlay
    }

    @objc private func playTapped() {
        onPlay?()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onPlay = nil
    }
}
```

- [ ] **Step 3: Build (no test — UIKit cells are build-verified)**

```bash
cd /Users/dfakkeldy/Developer/Echo && make build-tests
```

Expected: build succeeds (the cells compile in the test build of the Echo target).

- [ ] **Step 4: Commit**

```bash
cd /Users/dfakkeldy/Developer/Echo
git add EchoCore/Views/NoteFeedCell.swift EchoCore/Views/VoiceMemoFeedCell.swift
git commit -m "feat(feed): NoteFeedCell + VoiceMemoFeedCell (unified feed Phase 4)"
```

---

## Task 8: Register cells + dispatch the two new `ReaderCardItem` cases

Wire the cells into the open/extensible cell registry: two `register(...)` calls in `makeUIView` and two `case` branches in `cell(for:at:collectionView:)`. Route memo-play through a coordinator callback so cell selection is untouched (`didSelectItemAt` keeps matching only `.block`).

**Files:**
- Modify: `EchoCore/Views/ReaderFeedCollectionView.swift`

**Interfaces:**
- Consumes: `ReaderCardItem.note`, `.voiceMemo`; a new `onPlayMemo: ((VoiceMemoRecord) -> Void)?` coordinator hook.

- [ ] **Step 1: Add an `onPlayMemo` hook to the representable + coordinator**

In `EchoCore/Views/ReaderFeedCollectionView.swift`, add a stored closure to the `ReaderFeedCollectionView` struct alongside the existing `onTapBlock`/`onContextMenu` properties, and to the `Coordinator`. Locate the other `var onTap…` declarations on the struct by searching for `onTapBlock` — add next to them:

```swift
    var onPlayMemo: ((VoiceMemoRecord) -> Void)?
```

On the `Coordinator` class, add near `onTapBlock`/`onContextMenu` (search for `var onTapBlock` in the Coordinator):

```swift
        var onPlayMemo: ((VoiceMemoRecord) -> Void)?
```

In `updateUIView(_:context:)`, where `context.coordinator.onTapBlock = onTapBlock` and `onContextMenu` are assigned (locate by searching for `context.coordinator.onTapBlock`), add:

```swift
        context.coordinator.onPlayMemo = onPlayMemo
```

- [ ] **Step 2: Register the two cells**

In `makeUIView`, after the `ChapterDividerCell` registration (locate by searching `makeUIView` for `ChapterDividerCell`), add:

```swift
        collectionView.register(
            NoteFeedCell.self, forCellWithReuseIdentifier: NoteFeedCell.reuseIdentifier)
        collectionView.register(
            VoiceMemoFeedCell.self,
            forCellWithReuseIdentifier: VoiceMemoFeedCell.reuseIdentifier)
```

- [ ] **Step 3: Add the two dispatch branches**

In `cell(for:at:collectionView:)` (locate by searching for `func cell(for:`), after the `case .chapterHeader` branch and before `case .block`, add:

```swift
            case .note(let note):
                guard
                    let cell = collectionView.dequeueReusableCell(
                        withReuseIdentifier: NoteFeedCell.reuseIdentifier, for: indexPath
                    ) as? NoteFeedCell
                else { return UICollectionViewCell() }
                cell.configure(text: note.text)
                return cell

            case .voiceMemo(let memo):
                guard
                    let cell = collectionView.dequeueReusableCell(
                        withReuseIdentifier: VoiceMemoFeedCell.reuseIdentifier, for: indexPath
                    ) as? VoiceMemoFeedCell
                else { return UICollectionViewCell() }
                let durationText: String
                if let d = memo.duration {
                    durationText = "Voice memo · " + Duration.seconds(d)
                        .formatted(.time(pattern: .minuteSecond))
                } else {
                    durationText = "Voice memo"
                }
                cell.configure(durationText: durationText) { [weak self] in
                    self?.onPlayMemo?(memo)
                }
                return cell
```

> `cell(for:at:collectionView:)` is a `Coordinator` method (it references `self` indirectly via `card(for:)`), so `[weak self]` resolves to the coordinator and `onPlayMemo` is reachable. Confirm the method lives on the coordinator (it does — `card(for:)` and `dataSource` are coordinator members).

- [ ] **Step 4: Build**

```bash
cd /Users/dfakkeldy/Developer/Echo && make build-tests
```

Expected: build succeeds. The `switch item` is now exhaustive over all four `ReaderCardItem` cases (the compiler enforces this — if a case was missed, this build fails).

- [ ] **Step 5: Commit**

```bash
cd /Users/dfakkeldy/Developer/Echo
git add EchoCore/Views/ReaderFeedCollectionView.swift
git commit -m "feat(feed): register + dispatch note/voice-memo cells (unified feed Phase 4)"
```

---

## Task 9: `VoiceMemoRecorder` — standalone memo recording

An iOS AVAudioRecorder wrapper that records to an `.m4a` in the book folder and reports the saved URL + duration. Kept off the view model so the device/AVFoundation concern is isolated.

**Files:**
- Create: `EchoCore/Services/VoiceMemoRecorder.swift`

**Interfaces:**
- Produces: `@MainActor final class VoiceMemoRecorder` with `start() throws`, `stop() -> (url: URL, duration: TimeInterval)?`, `cancel()`, `var isRecording: Bool`.

- [ ] **Step 1: Create the recorder**

Create `EchoCore/Services/VoiceMemoRecorder.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import AVFoundation
import Foundation

/// Records a standalone voice memo to an `.m4a` in `destinationDirectory`.
/// Caller persists the returned URL/duration into `voice_memo` via `VoiceMemoDAO`.
@MainActor
final class VoiceMemoRecorder {
    private var recorder: AVAudioRecorder?
    private var currentURL: URL?
    private let destinationDirectory: URL

    var isRecording: Bool { recorder?.isRecording ?? false }

    init(destinationDirectory: URL) {
        self.destinationDirectory = destinationDirectory
    }

    /// Configures the audio session and begins recording a fresh `.m4a`.
    func start() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker])
        try session.setActive(true)

        try FileManager.default.createDirectory(
            at: destinationDirectory, withIntermediateDirectories: true)
        let url = destinationDirectory.appendingPathComponent("memo-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        let recorder = try AVAudioRecorder(url: url, settings: settings)
        guard recorder.record() else {
            throw NSError(
                domain: "VoiceMemoRecorder", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Failed to start recording"])
        }
        self.recorder = recorder
        self.currentURL = url
    }

    /// Stops recording and returns the file URL + measured duration, or nil if
    /// nothing was being recorded.
    func stop() -> (url: URL, duration: TimeInterval)? {
        guard let recorder, let url = currentURL else { return nil }
        let duration = recorder.currentTime
        recorder.stop()
        try? AVAudioSession.sharedInstance().setActive(false)
        self.recorder = nil
        self.currentURL = nil
        return (url, duration)
    }

    /// Aborts recording and deletes the partial file.
    func cancel() {
        recorder?.stop()
        if let url = currentURL { try? FileManager.default.removeItem(at: url) }
        try? AVAudioSession.sharedInstance().setActive(false)
        recorder = nil
        currentURL = nil
    }
}
```

- [ ] **Step 2: Build**

```bash
cd /Users/dfakkeldy/Developer/Echo && make build-tests
```

Expected: build succeeds. (No unit test — `AVAudioRecorder` requires audio hardware/session; this is verified on-device in Task 11.)

> Microphone permission: `VoiceMemoRecorder.start()` triggers the system mic prompt the first time. Confirm `NSMicrophoneUsageDescription` exists in the iOS app `Info.plist`. Run `grep -rn 'NSMicrophoneUsageDescription' --include='*.plist' --include='project.pbxproj' .` — if absent, add the key with a user-facing string (e.g. "Echo records voice memos you attach to passages while reading."). Note any addition in the PR body.

- [ ] **Step 3: Commit**

```bash
cd /Users/dfakkeldy/Developer/Echo
git add EchoCore/Services/VoiceMemoRecorder.swift
git commit -m "feat(feed): VoiceMemoRecorder — standalone .m4a capture (unified feed Phase 4)"
```

---

## Task 10: Capture UI + view-model wiring

The capture surface (`FeedCaptureBar`) and the view-model entry points that persist a note/memo at the current reading position and refresh the feed. The VM loads notes/memos in `reload()` and injects them via `FeedItemInjector`.

**Files:**
- Modify: `EchoCore/ViewModels/ReaderFeedViewModel.swift`
- Create: `EchoCore/Views/FeedCaptureBar.swift`
- Modify: `EchoCore/Views/ReaderTab.swift`
- Test: `EchoTests/ReaderFeedViewModelCaptureTests.swift`

**Interfaces:**
- Produces: `ReaderFeedViewModel.addNote(text:atBlockID:)`, `addVoiceMemo(fileURL:duration:atBlockID:)`; `FeedCaptureBar` SwiftUI overlay.
- Consumes (VM): `NoteDAO`, `VoiceMemoDAO`, `FeedItemInjector`.

- [ ] **Step 1: Write the failing VM test**

Create `EchoTests/ReaderFeedViewModelCaptureTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor
@Suite struct ReaderFeedViewModelCaptureTests {
    /// Seeds a book with one paragraph block so a note can anchor to it.
    private func seed(_ service: DatabaseService) throws {
        try service.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title) VALUES (?, ?)",
                arguments: ["bk1", "Book"])
        }
        let blockDAO = EPubBlockDAO(db: service.writer)
        let block = EPubBlockRecord(
            id: "b1", audiobookID: "bk1", spineHref: "c.xhtml", spineIndex: 0,
            blockIndex: 0, sequenceIndex: 0, blockKind: "paragraph",
            text: "Para", htmlContent: nil, cardColor: nil, chapterThemeColor: nil,
            imagePath: nil, chapterIndex: 0, isHidden: false, hiddenReason: nil,
            wordCount: nil, markers: nil, textFormats: nil,
            createdAt: nil, modifiedAt: nil)
        try blockDAO.insertAll([block])
    }

    @Test func addNoteThreadsNoteIntoFeedAfterBlock() throws {
        let service = try DatabaseService(inMemory: ())
        try seed(service)
        let vm = ReaderFeedViewModel(audiobookID: "bk1", db: service.writer)
        vm.reload()
        vm.addNote(text: "my note", atBlockID: "b1")

        // Phase 1 renders from `displaySections` (the expanded/collapsed view),
        // not the raw `sections`. Assert on displaySections after expanding the
        // chapter so block items are visible.
        let chapterIndex = 0
        vm.expandChapter(chapterIndex)  // ensure items are expanded
        let ids = vm.displaySections.flatMap { $0.items.map(\.id) }
        #expect(ids.contains("b-b1"))
        #expect(ids.contains { $0.hasPrefix("note-") })
        // Note sits immediately after its block.
        let bi = ids.firstIndex(of: "b-b1")!
        #expect(ids[bi + 1].hasPrefix("note-"))
    }

    @Test func addVoiceMemoThreadsMemoIntoFeed() throws {
        let service = try DatabaseService(inMemory: ())
        try seed(service)
        let vm = ReaderFeedViewModel(audiobookID: "bk1", db: service.writer)
        vm.reload()
        let url = URL(fileURLWithPath: "/tmp/memo.m4a")
        vm.addVoiceMemo(fileURL: url, duration: 3.0, atBlockID: "b1")

        // Assert on displaySections (Phase 1 rendering layer), not sections.
        let chapterIndex = 0
        vm.expandChapter(chapterIndex)
        let ids = vm.displaySections.flatMap { $0.items.map(\.id) }
        #expect(ids.contains { $0.hasPrefix("vm-") })
    }
}
```

> If `ReaderFeedViewModel.init`, `EPubBlockDAO.upsert`, or `DatabaseService.write` have a different exact signature on the rebased `nightly`, adjust the test to match (the recon confirms `init(audiobookID:db:)` with `db: DatabaseWriter` and `blockDAO`/`db` members; verify `upsert` vs the actual block-insert method name with `grep -n 'func ' Shared/Database/DAOs/EPubBlockDAO.swift`). Keep the assertions identical.

- [ ] **Step 2: Add DAOs + capture entry points to the VM**

In `EchoCore/ViewModels/ReaderFeedViewModel.swift`, add stored DAOs next to `blockDAO`/`chapterDAO` (`:16`–`:18`):

```swift
    private let noteDAO: NoteDAO
    private let voiceMemoDAO: VoiceMemoDAO
```

In `init` where `blockDAO`/`chapterDAO`/`db` are assigned (`:89`–`:91`), add:

```swift
        self.noteDAO = NoteDAO(db: db)
        self.voiceMemoDAO = VoiceMemoDAO(db: db)
```

Add stored caches of loaded notes/memos and fold injection into `rebuildDisplaySections()` so items appear in the Phase-1 rendering layer. **Do NOT replace the `sections =` assignment in `reload()` — Phase 1 makes `ReaderTab` read `vm.displaySections`, not `vm.sections`; injecting into `sections` means injected items are invisible in collapsed chapters and never appear at all until expansion is manually triggered.**

Instead:
1. Add two VM members to cache the lookups (call these in `reload()` after DAOs are ready):
```swift
    private var notesByBlockID: [String: [NoteRecord]] = [:]
    private var memosByBlockID: [String: [VoiceMemoRecord]] = [:]
```

2. In `reload()` (after `parsedSections` is fully built), populate the caches and then call `rebuildDisplaySections()`:
```swift
                let notes = (try? noteDAO.notes(for: audiobookID)) ?? []
                let memos = (try? voiceMemoDAO.memos(for: audiobookID)) ?? []
                notesByBlockID = Dictionary(
                    grouping: notes.filter { $0.epubBlockID != nil },
                    by: { $0.epubBlockID! })
                memosByBlockID = Dictionary(
                    grouping: memos.filter { $0.epubBlockID != nil },
                    by: { $0.epubBlockID! })
                rebuildDisplaySections()
```

3. In `rebuildDisplaySections()` (Phase 1 addition), after `ReaderFeedDisplayBuilder.displaySections(...)` produces sections from the current `parsedSections`/collapse state, pipe the output through `FeedItemInjector`:
```swift
        let built = ReaderFeedDisplayBuilder.displaySections(
            from: parsedSections,
            chapterGroups: chapterGroups,
            expandedChapters: expandedChapters)
        displaySections = FeedItemInjector.inject(
            into: built,
            notesByBlockID: notesByBlockID,
            memosByBlockID: memosByBlockID)
```

> Confirm the exact shape of `rebuildDisplaySections()` by reading it after the Phase 1 rebase. The key invariant: injection happens on the **output** of the display builder (which already applies collapse filtering), so collapsed chapters keep only `[.chapterHeader]` and injected items are only visible when the chapter is expanded — which matches the spec's behaviour.
>
> Also confirm that `addNote`/`addVoiceMemo` call `reload()` (which re-populates caches + triggers `rebuildDisplaySections()`) rather than calling `rebuildDisplaySections()` directly, so the DB write is reflected accurately.

Add the two capture methods (place them after `reload()`):

```swift
    /// Persists a free-text note anchored to `blockID` at the current reading
    /// position, then refreshes the feed so it appears inline.
    func addNote(text: String, atBlockID blockID: String) {
        let now = Date().ISO8601Format()
        let note = NoteRecord(
            id: UUID().uuidString,
            audiobookID: audiobookID,
            text: text,
            mediaTimestamp: -1,
            realTimestamp: now,
            isEnabled: true,
            playlistPosition: nil,
            createdAt: now,
            modifiedAt: now,
            epubBlockID: blockID)
        do {
            try noteDAO.insert(note)
        } catch {
            logger.error("addNote failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        reload()
    }

    /// Persists a standalone voice memo (already recorded to `fileURL`) anchored
    /// to `blockID`, then refreshes the feed.
    func addVoiceMemo(fileURL: URL, duration: TimeInterval, atBlockID blockID: String) {
        let now = Date().ISO8601Format()
        let memo = VoiceMemoRecord(
            id: UUID().uuidString,
            audiobookID: audiobookID,
            epubBlockID: blockID,
            mediaTimestamp: -1,
            filePath: fileURL.lastPathComponent,
            duration: duration,
            isEnabled: true,
            createdAt: now,
            modifiedAt: now)
        do {
            try voiceMemoDAO.insert(memo)
        } catch {
            logger.error("addVoiceMemo failed: \(error.localizedDescription, privacy: .public)")
            return
        }
        reload()
    }
```

> The capture methods take an explicit `blockID`. The view passes the **currently-visible / active** block (the VM already tracks `activeBlockID` for playback sync — use that as the default anchor in `ReaderTab` when no block is long-pressed). `mediaTimestamp: -1` matches the codebase convention for "no audio anchor" (see `TimelineItem.isTimestamped`, `Shared/Database/TimelineItem.swift:92`); positioning is by `epubBlockID`, not audio time.

- [ ] **Step 3: Create the capture overlay**

Create `EchoCore/Views/FeedCaptureBar.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

/// A compact capture overlay for the reader feed: add a note, or record a voice
/// memo. Both anchor to the supplied block. iOS only.
struct FeedCaptureBar: View {
    /// The block the new note/memo will anchor to (typically the active block).
    let anchorBlockID: String?
    let onAddNote: (_ text: String, _ blockID: String) -> Void
    let onStartRecording: () -> Void
    let onStopRecording: (_ blockID: String) -> Void

    @State private var isComposingNote = false
    @State private var noteText = ""
    @State private var isRecording = false

    var body: some View {
        HStack(spacing: 16) {
            Button {
                isComposingNote = true
            } label: {
                Label("Add note", systemImage: "note.text.badge.plus")
            }
            .disabled(anchorBlockID == nil)

            Button {
                if isRecording {
                    if let id = anchorBlockID { onStopRecording(id) }
                    isRecording = false
                } else {
                    onStartRecording()
                    isRecording = true
                }
            } label: {
                Label(
                    isRecording ? "Stop" : "Record memo",
                    systemImage: isRecording ? "stop.circle.fill" : "mic.circle")
            }
            .disabled(anchorBlockID == nil)
            .tint(isRecording ? .red : .accentColor)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
        .sheet(isPresented: $isComposingNote) {
            NavigationStack {
                TextEditor(text: $noteText)
                    .padding()
                    .navigationTitle("New Note")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") {
                                noteText = ""
                                isComposingNote = false
                            }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") {
                                if let id = anchorBlockID,
                                    !noteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                {
                                    onAddNote(noteText, id)
                                }
                                noteText = ""
                                isComposingNote = false
                            }
                        }
                    }
            }
        }
    }
}
```

- [ ] **Step 4: Present the capture bar + wire callbacks in `ReaderTab`**

In `EchoCore/Views/ReaderTab.swift`, hold a `VoiceMemoRecorder` and an `AVAudioPlayer?` for playback, and present `FeedCaptureBar` as a bottom overlay on the reader feed.

**Resolve the book folder URL first.** Run:
```bash
grep -n 'folderURL\|bookFolder\|audiobookFolder\|bookDirectory' EchoCore/Views/ReaderTab.swift EchoCore/ViewModels/ReaderFeedViewModel.swift
```
Use whatever URL the tab/VM already resolves as the book folder. Pass it to `VoiceMemoRecorder` so memo `.m4a` files land in the book folder and the relative `filePath` (stored in `addVoiceMemo`) resolves correctly after relaunch. Only fall back to `temporaryDirectory` if no book-folder URL is available in `ReaderTab`'s scope — and if so, note it in the PR body as a follow-up.

**Wire `onPlayMemo` to a real `AVAudioPlayer`.** The `VoiceMemoFeedCell` fires `onPlay` → `Coordinator.onPlayMemo` → this closure. Without a real player, tapping play is a no-op and Task 11 smoke item 3 fails. Add these to `ReaderTab`:

```swift
    @State private var memoPlayer: AVAudioPlayer?
    // Set destinationDirectory to the resolved book-folder URL (see above).
    @State private var memoRecorder = VoiceMemoRecorder(
        destinationDirectory: <resolvedBookFolderURL>
            .appendingPathComponent("voice-memos", isDirectory: true))
```

Add to the reader feed container (e.g. as `.overlay(alignment: .bottom)`):

```swift
        .overlay(alignment: .bottom) {
            FeedCaptureBar(
                anchorBlockID: vm.activeBlockID,
                onAddNote: { text, blockID in
                    vm.addNote(text: text, atBlockID: blockID)
                },
                onStartRecording: {
                    try? memoRecorder.start()
                },
                onStopRecording: { blockID in
                    if let result = memoRecorder.stop() {
                        vm.addVoiceMemo(
                            fileURL: result.url, duration: result.duration, atBlockID: blockID)
                    }
                })
            .padding(.bottom, 12)
        }
```

Pass the play closure into the `ReaderFeedCollectionView` representable wherever `onPlayMemo` is set (it is a `var` on the struct — see Task 8 Step 1):

```swift
        ReaderFeedCollectionView(...)
            .onPlayMemo { memo in
                // Resolve the absolute URL from the stored relative filePath.
                let bookFolder = <resolvedBookFolderURL>
                    .appendingPathComponent("voice-memos", isDirectory: true)
                let fileURL = bookFolder.appendingPathComponent(memo.filePath)
                memoPlayer?.stop()
                memoPlayer = try? AVAudioPlayer(contentsOf: fileURL)
                memoPlayer?.play()
            }
```

> `vm.activeBlockID` must be accessible from `ReaderTab`; the recon confirms the VM tracks the active block (`activeBlockID` is read in the cell path). If it is `private(set)`/internal, it is readable from the same module — confirm and, if private, expose it `private(set) var`.
>
> **Note:** `addVoiceMemo` stores `fileURL.lastPathComponent` in `filePath` (i.e. a relative name, not an absolute path). The play closure above re-joins it with the memo subdirectory so the file is found correctly after relaunch. If the recording uses a different directory layout, adjust the join to match.

- [ ] **Step 5: Build + run the VM test**

```bash
cd /Users/dfakkeldy/Developer/Echo && make build-tests && make test-only FILTER=EchoTests/ReaderFeedViewModelCaptureTests
```

Expected: `ReaderFeedViewModelCaptureTests` passes, both tests green; the full build succeeds.

- [ ] **Step 6: Commit**

```bash
cd /Users/dfakkeldy/Developer/Echo
git add EchoCore/ViewModels/ReaderFeedViewModel.swift EchoCore/Views/FeedCaptureBar.swift EchoCore/Views/ReaderTab.swift EchoTests/ReaderFeedViewModelCaptureTests.swift
git commit -m "feat(feed): note/voice-memo capture UI + VM wiring (unified feed Phase 4)"
```

---

## Task 11: Full-suite verification, on-device smoke, doc-sync, PR

**Files:**
- Modify: `CHANGELOG.md`

- [ ] **Step 1: Run the full EchoTests suite (confirm no regressions)**

```bash
cd /Users/dfakkeldy/Developer/Echo && make test-only FILTER=EchoTests
```

Expected: all suites pass (or only the pre-existing known failures noted in MEMORY — `VoiceCatalogTests` "trim to Ava", and any `PlayerModel` teardown crashes the gate already excludes). The six new suites (`SchemaV24Tests`, `VoiceMemoDAOTests`, `NoteDAOEpubBlockTests`, `TimelineItemTypePhase4Tests`, `ReaderCardItemPhase4Tests`, `FeedItemInjectorTests`, `ReaderFeedViewModelCaptureTests`) all green. If a new failure appears that is NOT pre-existing, fix it before proceeding (use systematic-debugging).

- [ ] **Step 2: On-device / simulator smoke (manual)**

Run the app on the `iPhone 17` simulator (or a device). Open a book in the reader feed. Verify:
1. Tapping "Add note" → composer → Save inserts a note row directly under the active block.
2. Tapping "Record memo" prompts for mic permission (first time), records, "Stop" inserts a memo row under the active block.
3. Tapping a memo's play button plays the audio without selecting the cell / seeking.
4. Re-opening the book shows the persisted note/memo rows in document order.

Document any visual-polish gaps (spacing, icon) as follow-ups — not code placeholders.

- [ ] **Step 3: Doc-sync (CLAUDE.md requirement)**

Phase 4 adds a feature (new content types + capture) AND changes the schema (V24) — both trigger the doc-sync rule. Add a CHANGELOG entry under the unreleased/nightly section:

```markdown
### Added
- Reader feed now supports two new inline content types: free-text **notes** and **voice memos**, captured directly while reading and threaded into the feed at the passage they belong to. Notes carry an EPUB block position; voice memos are stored as standalone audio recordings.
```

Then **remind the user** that `ARCHITECTURE.md` (database schema + reader feed sections) and `ROADMAP.md` (unified-feed phase tracker) need a line about Phase 4 + the V24 migration, and offer the snippet. Invoke the `doc-sync` skill for the full pass before opening the PR. Do not silently rewrite ARCHITECTURE.md — offer the snippet.

- [ ] **Step 4: Run schema-migration-reviewer one more time (final gate)**

Confirm the V24 number is still free on the now-current `nightly` (a sibling phase may have merged a migration meanwhile). If collided, renumber (file, enum, registration string, test suite) and re-run Step 1.

- [ ] **Step 5: Commit + open the PR**

```bash
cd /Users/dfakkeldy/Developer/Echo
git add CHANGELOG.md
git commit -m "docs(changelog): notes + voice memos in the reader feed (unified feed Phase 4)"
git push -u origin feature/unified-feed-phase4
gh pr create --base nightly --title "feat(feed): unified feed Phase 4 — notes + voice memos (iOS)" --body "Implements Phase 4 of the unified-feed initiative (spec §8, §10, §12). Adds two new TimelineItemType values (.note, .voiceMemo) and two ReaderCardItem cases threaded into the collapsible feed at EPUB document position. Notes gain an epub_block_id column; voice memos get a net-new standalone voice_memo table (distinct from bookmark.voice_memo_path). Capture UI (Add note / Record memo) ships this phase. Schema migration V24 (re-verify number on nightly) with SchemaV24Tests + schema-migration-reviewer. CloudKit checked: no record type touches note/voice_memo. Cell registry stays open: new types slot in via two register() calls + two switch cases. Out of scope: Phase 3 session_location write path, off-switch, macOS parity, word-tap-to-seek."
```

---

## Self-Review

**1. Spec coverage (Phase 4 scope per spec §8, §10, §12 and the recon action items):**
- TWO new `TimelineItem.item_type` values (`voiceMemo`, `note`): Task 4. ✓
- Notes already have a `note` table (Schema_V2); only `epub_block_id` added: Task 1 (item 1) + Task 3. ✓
- Voice-memo storage = audio file + row is net-new (standalone `voice_memo` table, not `bookmark.voice_memo_path`): Task 1 (item 2) + Task 2 + Task 9. Open question resolved + flagged for owner. ✓
- Cell registry stays open/extensible (new types slot in without rewriting the engine): Task 8 — two `register()` calls + two `switch` cases; the compiler's exhaustiveness check enforces completeness. ✓
- Capture UI for memos/notes is THIS phase (no half-built capture earlier): Task 9 (`VoiceMemoRecorder`) + Task 10 (`FeedCaptureBar` + VM entry points). ✓
- Schema migration with next free version + SchemaVxxTests + schema-migration-reviewer: Task 1 (Step 1 confirms free version; Step 7 + Task 11 Step 4 run the reviewer twice). ✓
- CloudKit sync caution (§7.2/§10): Task 1 Step 5 greps for record-type mappings before adding columns. ✓
- Mirrors how bookmarks/cards became feed items in Phase 2: `FeedItemInjector` (Task 6) injects by block position exactly as the Phase 2 pattern; new `ReaderCardItem` cases (Task 5) follow the same id-prefix + manual-Hashable shape as Phase 2's bookmark/card cases. ✓
- Recon item 9 (legacy `"note"` → `.bookmark` must become `.note`): Task 4 Step 3. ✓
- Recon item 8 (`NoteDAO` positional query): Task 3 Step 3. ✓

**2. Placeholder scan:** every code step shows the full Swift; every test step shows the full test + the exact `make` command + expected output. No "TBD" / "add error handling" / "similar to Task N". The deferred items are documented *defaults with owner-review flags* (memo-destination directory, mic-usage plist string, exact `EPubBlockDAO` insert method name), each with a concrete grep to resolve at execution time — these are verification steps, not code gaps.

**3. Type consistency:**
- `epubBlockID` / `epub_block_id` — identical column name across `Schema_V24` (Task 1), `NoteRecord`/`VoiceMemoRecord` coding keys (Tasks 2/3), DAO filters (Tasks 2/3). ✓
- `VoiceMemoRecord` field order (`id, audiobookID, epubBlockID, mediaTimestamp, filePath, duration, isEnabled, createdAt, modifiedAt`) — identical in the struct (Task 2), every test fixture (Tasks 2/5/6/10), and the VM memberwise call (Task 10). ✓
- `NoteRecord` memberwise call order with `epubBlockID` last (`= nil` default) — identical across Tasks 3/5/6/10. ✓
- `ReaderCardItem` ids: `"note-\(note.id)"` / `"vm-\(memo.id)"` — identical in the enum (Task 5), `FeedItemInjector` output assertions (Task 6), and VM-capture assertions (Task 10). ✓
- `FeedItemInjector.inject(into:notesByBlockID:memosByBlockID:)` — identical signature Task 6 definition ↔ Task 10 call site. ✓
- `VoiceMemoDAO.memos(withEpubBlockIDsIn:audiobookID:)` / `NoteDAO.notes(withEpubBlockIDsIn:audiobookID:)` — identical names Tasks 2/3. ✓
- Hashable discriminators `0/1/2/3` for `chapterHeader/block/note/voiceMemo` — consistent across `==`/`hash` (Task 5). ✓
- New cells `NoteFeedCell.reuseIdentifier` / `VoiceMemoFeedCell.reuseIdentifier` — identical in cell definitions (Task 7), `register()` (Task 8 Step 2), and `dequeueReusableCell` (Task 8 Step 3). ✓

**Known risks carried into execution (each has a verification step):**
- **Migration version collision** — V24 may be taken by a sibling phase. Pinned by Task 1 Step 1 and re-checked at Task 11 Step 4.
- **`NoteRecord` memberwise-init break** — adding a non-defaulted field breaks existing callers; mitigated by `= nil` default (Task 3 Step 2) and the full-suite build (Task 11 Step 1).
- **Injection into `displaySections` (Phase 1 layer)** — Phase 1 makes `ReaderTab` read `vm.displaySections`, not `vm.sections`. Injection is folded into `rebuildDisplaySections()` and tests assert on `displaySections` (Task 10). Locate `rebuildDisplaySections()` by name after rebase.
- **Memo destination directory + mic plist** — must use the book folder (not `temporaryDirectory`) so the relative `filePath` resolves after relaunch; see the grep in Task 10 Step 4. Requires `NSMicrophoneUsageDescription` in `Info.plist` (grep in Task 9 Step 2).
- **`onPlayMemo` must be wired to a real `AVAudioPlayer`** — the closure passed into `ReaderFeedCollectionView` in `ReaderTab` must actually play the file; see Task 10 Step 4. Without it, Task 11 smoke item 3 fails.
- **`vm.activeBlockID` visibility** — readable in-module; confirm not `private` (Task 10 Step 4).
- **CloudKit** — local-only assumed; verified by grep before merge (Task 1 Step 5).
- **`legacyRawValue` remap safety** — confirmed read-only by grep before changing (Task 4 Step 3).
- **Exhaustive `switch`** — the cell-dispatch `switch` over `ReaderCardItem` becomes a compile-time completeness gate after Task 5; Task 8 build catches any missed case.
- **`withEpubBlockIDsIn` DAO methods** — tested but not called in the VM shipping path (VM uses `notes(for:)`/`memos(for:)` + in-memory grouping); documented in the DAO doccomments as available for future per-chapter loading.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-22-unified-feed-phase4.md`. Two execution options:

1. **Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration. (Tell each implementer: builds run in the **foreground** with `timeout: 600000`; confirm the overnight build slot is idle first; rebase onto the latest `nightly` so Phases 1–3 shapes match; re-confirm the migration version is free.)
2. **Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
