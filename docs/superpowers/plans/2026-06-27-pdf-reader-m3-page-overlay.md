# PDF Reader M3 — Page Auto-Follow + Define-on-Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a narrated PDF plays in page mode, the page auto-follows the narration, the active word is highlighted on the page (best-effort), and long-press offers Look Up + Save — all reusing the existing resolver and M2's vocabulary builders.

**Architecture:** Capture each block's source PAGE INDEX at import into a new V26 `pdf_block_page` table (the char-offset approach was proven infeasible — the shared PDF→text parser normalizes/concatenates before blocks exist; see spec §5). At render, `PDFDocumentView` observes `model.currentPlaybackTime`, resolves the active block/word via the shared `ReaderActiveBlockResolver`, auto-follows the `PDFView` to the block's page, and highlights the active word by **PDFKit text search** (tolerant of whitespace/normalization differences). Long-press reads the word directly from the PDF and offers Look Up + Save.

**Tech Stack:** Swift 6, GRDB (V26 migration), PDFKit (`PDFView`/`PDFPage`/`PDFSelection`/`findString`), UIKit, Swift Testing.

## Global Constraints

- **Swift 6** (`-default-isolation MainActor`); pure DB types `nonisolated`/`Sendable`; view + overlay `@MainActor`.
- **SPDX header line 1** of every new file. SwiftFormat hook reflows on edit — re-confirm SPDX line 1.
- **Tests are Swift Testing**, module `Echo`, in-memory DB via `DatabaseService(inMemory: ())`. Migration tests mirror `EchoTests/SchemaV25Tests.swift`. PDF capture tests reuse `EchoTests/Support/TestPDFFixture.swift` (added by PR #183).
- **iOS deployment target 18.0.** iOS-only (the macOS reader has no PDF surface).
- **Build/test** (16 GB Mac — never two `xcodebuild`s; gate every build): `"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests` → `** TEST BUILD SUCCEEDED **` (no `make build`). Run a suite: `make test-only FILTER=EchoTests/<Suite>` (use test-only for real Swift Testing output).
- **Migration discipline:** current max migration is **V25** (`v25_study_plans`). Register V26 as `v26_pdf_block_page` AFTER V25 in `DatabaseService.runMigrations`. Run the `schema-migration-reviewer` agent before committing Task 1. Use `AUTOINCREMENT` integer PK + `ifNotExists: true` like `Schema_V25`.
- **Reuse, don't duplicate:** the active-block/word resolution is `ReaderActiveBlockResolver` (do NOT reinvent); Look Up is M2's `DictionaryLookupPresenter`; Save is M2's `VocabularyCardBuilder` + `FlashcardDAO.vocabularyCard` + `FreeTierGate` cap.
- **Do not regress** the existing PDF page view: long-press alignment options, state restore (`PDFViewState`), the bottom action menu must keep working.
- **Verifiability:** Tasks 1–2 are build + unit-testable. Tasks 3–4 are runtime-only (overlay positioning, coordinate conversion, search highlight, gesture) — build-green is necessary but NOT sufficient; the on-device checklist at the end is the real gate. Implementers must label what is verified vs deferred.
- **Spec:** `docs/superpowers/specs/2026-06-26-pdf-alignment-define-design.md` (§5 + §6.2 REVISED). This plan = milestone **M3**.

---

## File Structure

| File | Responsibility | New/Modify |
|------|----------------|-----------|
| `Shared/Database/Migrations/Schema_V26.swift` | V26 migration: `pdf_block_page` table + indexes | **Create** |
| `Shared/Database/DatabaseService.swift` | register `v26_pdf_block_page` after V25 | **Modify** |
| `Shared/Database/PDFBlockPageRecord.swift` | GRDB record for `pdf_block_page` | **Create** |
| `Shared/Database/DAOs/PDFBlockPageDAO.swift` | insert/fetch/deleteAll for `pdf_block_page` | **Create** |
| `EchoTests/SchemaV26Tests.swift` | migration creates table + indexes | **Create** |
| `EchoCore/Services/PDFBlockPageMapper.swift` | pure: map blocks → page index from `[page strings]` | **Create** |
| `EchoCore/Services/PDFAutoImportScanner.swift` | after import, persist `pdf_block_page` rows | **Modify** |
| `EchoTests/PDFBlockPageMapperTests.swift` | mapper unit tests | **Create** |
| `EchoTests/PDFBlockPageCaptureTests.swift` | end-to-end import → rows (fixture PDF) | **Create** |
| `EchoCore/Views/PDFReadAlongController.swift` | observes time → resolver → active page/word | **Create** |
| `EchoCore/Views/PDFDocumentView.swift` | wire the controller: page auto-follow + word overlay + define long-press | **Modify** |

---

### Task 1: V26 `pdf_block_page` schema + record + DAO — TDD

**Files:** Create `Schema_V26.swift`, `PDFBlockPageRecord.swift`, `DAOs/PDFBlockPageDAO.swift`, `EchoTests/SchemaV26Tests.swift`; Modify `DatabaseService.swift`.

**Interfaces — Produces:**
- table `pdf_block_page(id INTEGER PK AUTOINCREMENT, audiobook_id TEXT NOT NULL, epub_block_id TEXT NOT NULL, page_index INTEGER NOT NULL)` + indexes `idx_pdf_block_page_book` (audiobook_id, epub_block_id) and `idx_pdf_block_page_page` (audiobook_id, page_index).
- `struct PDFBlockPageRecord` (id: Int64?, audiobookID, epubBlockID, pageIndex)
- `struct PDFBlockPageDAO { init(db: DatabaseWriter); func insert(_:) throws; func deleteAll(for:) throws; func pageIndex(for audiobookID: String, epubBlockID: String) throws -> Int?; func rows(for audiobookID: String) throws -> [PDFBlockPageRecord] }`

- [ ] **Step 1: Write the failing migration test**

Create `EchoTests/SchemaV26Tests.swift` (mirror `SchemaV25Tests`):

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@MainActor @Suite struct SchemaV26Tests {
    private func columnNames(table: String, db: DatabaseService) throws -> Set<String> {
        try db.writer.read { database in
            let rows = try Row.fetchAll(database, sql: "PRAGMA table_info(\(table))")
            return Set(rows.compactMap { $0["name"] as? String })
        }
    }
    private func indexNames(table: String, db: DatabaseService) throws -> Set<String> {
        try db.writer.read { database in
            let rows = try Row.fetchAll(database, sql: "PRAGMA index_list(\(table))")
            return Set(rows.compactMap { $0["name"] as? String })
        }
    }

    @Test func v26CreatesPdfBlockPageTable() throws {
        let db = try DatabaseService(inMemory: ())
        let cols = try columnNames(table: "pdf_block_page", db: db)
        #expect(cols.contains("id"))
        #expect(cols.contains("audiobook_id"))
        #expect(cols.contains("epub_block_id"))
        #expect(cols.contains("page_index"))
    }

    @Test func v26CreatesIndexes() throws {
        let db = try DatabaseService(inMemory: ())
        let idx = try indexNames(table: "pdf_block_page", db: db)
        #expect(idx.contains("idx_pdf_block_page_book"))
        #expect(idx.contains("idx_pdf_block_page_page"))
    }

    @Test func daoRoundTrips() throws {
        let db = try DatabaseService(inMemory: ())
        let dao = PDFBlockPageDAO(db: db.writer)
        try dao.insert(PDFBlockPageRecord(id: nil, audiobookID: "b1", epubBlockID: "blk1", pageIndex: 3))
        #expect(try dao.pageIndex(for: "b1", epubBlockID: "blk1") == 3)
        #expect(try dao.pageIndex(for: "b1", epubBlockID: "nope") == nil)
        try dao.deleteAll(for: "b1")
        #expect(try dao.pageIndex(for: "b1", epubBlockID: "blk1") == nil)
    }
}
```

> Verify the `DatabaseService(inMemory:)` `.writer` accessor name against the real type (the `SchemaV25Tests` helper used `db.read`/`db.writer` — match whatever compiles).

- [ ] **Step 2: Run to verify failure**

Run: `"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests` → FAIL (`pdf_block_page` missing / `PDFBlockPageRecord` unknown).

- [ ] **Step 3: Implement migration, record, DAO, registration**

Create `Shared/Database/Migrations/Schema_V26.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

/// V26 — per-block source PDF page index, for page-mode read-along auto-follow.
/// (Char-offset geometry was infeasible; see the M3 spec §5.)
enum Schema_V26 {
    nonisolated static func migrate(_ db: Database) throws {
        try db.create(table: "pdf_block_page", ifNotExists: true) { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("audiobook_id", .text).notNull()
            t.column("epub_block_id", .text).notNull()
            t.column("page_index", .integer).notNull()
        }
        try db.create(
            index: "idx_pdf_block_page_book", on: "pdf_block_page",
            columns: ["audiobook_id", "epub_block_id"], ifNotExists: true)
        try db.create(
            index: "idx_pdf_block_page_page", on: "pdf_block_page",
            columns: ["audiobook_id", "page_index"], ifNotExists: true)
    }
}
```

In `Shared/Database/DatabaseService.swift`, register after the V25 line:

```swift
    migrator.registerMigration("v26_pdf_block_page") { db in
        try Schema_V26.migrate(db)
    }
```

Create `Shared/Database/PDFBlockPageRecord.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

struct PDFBlockPageRecord: Identifiable, Equatable, Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var audiobookID: String
    var epubBlockID: String
    var pageIndex: Int

    static let databaseTableName = "pdf_block_page"

    enum CodingKeys: String, CodingKey {
        case id
        case audiobookID = "audiobook_id"
        case epubBlockID = "epub_block_id"
        case pageIndex = "page_index"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
```

> Match `didInsert` to the project's GRDB version (see `WordTimingRecord` for the exact `didInsert` signature it uses — copy that form).

Create `Shared/Database/DAOs/PDFBlockPageDAO.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

struct PDFBlockPageDAO {
    let db: DatabaseWriter

    func insert(_ record: PDFBlockPageRecord) throws {
        var mutable = record
        try db.write { db in try mutable.insert(db) }
    }

    func insertAll(_ records: [PDFBlockPageRecord]) throws {
        try db.write { db in
            for var r in records { try r.insert(db) }
        }
    }

    func deleteAll(for audiobookID: String) throws {
        _ = try db.write { db in
            try PDFBlockPageRecord.filter(Column("audiobook_id") == audiobookID).deleteAll(db)
        }
    }

    func pageIndex(for audiobookID: String, epubBlockID: String) throws -> Int? {
        try db.read { db in
            try PDFBlockPageRecord
                .filter(Column("audiobook_id") == audiobookID)
                .filter(Column("epub_block_id") == epubBlockID)
                .fetchOne(db)?.pageIndex
        }
    }

    func rows(for audiobookID: String) throws -> [PDFBlockPageRecord] {
        try db.read { db in
            try PDFBlockPageRecord.filter(Column("audiobook_id") == audiobookID).fetchAll(db)
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests && make test-only FILTER=EchoTests/SchemaV26Tests` → all pass. SPDX line 1 on new files.

- [ ] **Step 5: Commit** (after the schema-migration-reviewer agent approves — the controller runs it)

```bash
git add Shared/Database/Migrations/Schema_V26.swift Shared/Database/DatabaseService.swift Shared/Database/PDFBlockPageRecord.swift Shared/Database/DAOs/PDFBlockPageDAO.swift EchoTests/SchemaV26Tests.swift
git commit -m "feat(db): V26 pdf_block_page table + record + DAO"
```

---

### Task 2: Capture per-block page index at import — TDD

**Files:** Create `EchoCore/Services/PDFBlockPageMapper.swift`, `EchoTests/PDFBlockPageMapperTests.swift`, `EchoTests/PDFBlockPageCaptureTests.swift`; Modify `EchoCore/Services/PDFAutoImportScanner.swift`.

**Interfaces — Produces:**
- `enum PDFBlockPageMapper { static func map(blocks: [(id: String, text: String)], pages: [String]) -> [(blockID: String, pageIndex: Int)] }` — pure; assigns each block the page whose raw text contains it (normalized, whitespace-insensitive), advancing a cursor so sequential blocks resolve monotonically.

- [ ] **Step 1: Write the failing mapper test**

Create `EchoTests/PDFBlockPageMapperTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct PDFBlockPageMapperTests {
    @Test func assignsBlocksToTheirSourcePage() {
        let pages = [
            "Chapter One\nThe quick brown fox jumps over the lazy dog.",
            "Chapter Two\nA second page with different words entirely here.",
        ]
        let blocks = [
            (id: "b0", text: "Chapter One"),
            (id: "b1", text: "The quick brown fox jumps over the lazy dog."),
            (id: "b2", text: "Chapter Two"),
            (id: "b3", text: "A second page with different words entirely here."),
        ]
        let result = PDFBlockPageMapper.map(blocks: blocks, pages: pages)
        #expect(result.first(where: { $0.blockID == "b0" })?.pageIndex == 0)
        #expect(result.first(where: { $0.blockID == "b1" })?.pageIndex == 0)
        #expect(result.first(where: { $0.blockID == "b2" })?.pageIndex == 1)
        #expect(result.first(where: { $0.blockID == "b3" })?.pageIndex == 1)
    }

    @Test func toleratesWhitespaceAndCaseDifferences() {
        let pages = ["the   QUICK\nbrown fox"]
        let blocks = [(id: "b0", text: "The quick brown fox")]
        #expect(PDFBlockPageMapper.map(blocks: blocks, pages: pages).first?.pageIndex == 0)
    }

    @Test func unmatchedBlockFallsBackToLastKnownPage() {
        let pages = ["page zero text", "page one text"]
        let blocks = [
            (id: "b0", text: "page zero text"),
            (id: "b1", text: "synthetic heading not on any page"),
            (id: "b2", text: "page one text"),
        ]
        let r = PDFBlockPageMapper.map(blocks: blocks, pages: pages)
        #expect(r.first(where: { $0.blockID == "b0" })?.pageIndex == 0)
        #expect(r.first(where: { $0.blockID == "b1" })?.pageIndex == 0)  // carries previous
        #expect(r.first(where: { $0.blockID == "b2" })?.pageIndex == 1)
    }
}
```

- [ ] **Step 2: Run to verify failure** — `make build-tests` → FAIL (`PDFBlockPageMapper` unknown).

- [ ] **Step 3: Implement the mapper**

Create `EchoCore/Services/PDFBlockPageMapper.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Maps each imported block to the source PDF page whose raw text contains it.
/// Whitespace/case-insensitive; advances a page cursor so sequential blocks
/// resolve monotonically and an unmatched (e.g. synthetic-heading) block
/// carries the previous block's page.
enum PDFBlockPageMapper {
    static func map(
        blocks: [(id: String, text: String)], pages: [String]
    ) -> [(blockID: String, pageIndex: Int)] {
        let norm = pages.map { normalize($0) }
        var cursor = 0
        var out: [(blockID: String, pageIndex: Int)] = []
        for block in blocks {
            let needle = normalize(block.text)
            var found: Int?
            if !needle.isEmpty {
                // Prefer the current page or later (monotonic reading order).
                for p in cursor..<norm.count where norm[p].contains(needle) { found = p; break }
                if found == nil {
                    for p in 0..<norm.count where norm[p].contains(needle) { found = p; break }
                }
            }
            let page = found ?? cursor
            cursor = max(cursor, page)
            out.append((blockID: block.id, pageIndex: page))
        }
        return out
    }

    private static func normalize(_ s: String) -> String {
        s.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
```

> The needle is the whole block text; for very long blocks `contains` is O(n·m). Acceptable at import time. If a block is longer than its page slice (reflow across the page-join), `contains` may miss → falls back to `cursor` (previous page), which is the correct monotonic guess.

- [ ] **Step 4: Run mapper test to pass** — `make test-only FILTER=EchoTests/PDFBlockPageMapperTests` → pass.

- [ ] **Step 5: Wire capture into the importer + end-to-end test**

In `PDFAutoImportScanner`, after `DocumentImportFinalizer.finalize(...)` succeeds (the importer already produced `blocks` and `extractedText.pages` is in scope), persist the mapping:

```swift
    // After finalize succeeds, record each block's source page (page mode auto-follow).
    let mapping = PDFBlockPageMapper.map(
        blocks: blocks.map { (id: $0.id, text: $0.text ?? "") },
        pages: extractedText.pages)
    let dao = PDFBlockPageDAO(db: databaseService.writer)
    try? dao.deleteAll(for: audiobookID)
    try? dao.insertAll(mapping.map {
        PDFBlockPageRecord(id: nil, audiobookID: audiobookID, epubBlockID: $0.blockID, pageIndex: $0.pageIndex)
    })
```

> Place this where both `blocks` and `extractedText` are in scope (the `importPDFFile`/`importPDFFileOutcome` path). Keep it off the main actor consistent with the surrounding import code. Use `try?` so a geometry-capture failure never aborts a successful import.

Create `EchoTests/PDFBlockPageCaptureTests.swift` (reuse `TestPDFFixture`):

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@MainActor @Suite struct PDFBlockPageCaptureTests {
    @Test func importPopulatesPdfBlockPageRows() async throws {
        let db = try DatabaseService(inMemory: ())
        let pdfURL = try TestPDFFixture.twoPages()   // use the fixture's multi-page maker
        let audiobookID = pdfURL.absoluteString
        _ = await PDFAutoImportScanner.importPDFFile(
            pdfURL: pdfURL, audiobookID: audiobookID, databaseService: db,
            chapters: [], duration: nil, force: true)
        let rows = try PDFBlockPageDAO(db: db.writer).rows(for: audiobookID)
        #expect(!rows.isEmpty)
        #expect(rows.contains { $0.pageIndex == 0 })
        #expect(rows.contains { $0.pageIndex == 1 })
    }
}
```

> Match `TestPDFFixture`'s actual multi-page API name (the report noted a two-chapter/in-page-marker fixture exists; use whichever produces ≥2 pages) and `importPDFFile`'s actual signature. If the fixture only makes single-page PDFs, assert `rows.allSatisfy { $0.pageIndex == 0 }` instead and note it.

- [ ] **Step 6: Run + commit**

Run: `make test-only FILTER=EchoTests/PDFBlockPageMapperTests && make test-only FILTER=EchoTests/PDFBlockPageCaptureTests` → pass.

```bash
git add EchoCore/Services/PDFBlockPageMapper.swift EchoCore/Services/PDFAutoImportScanner.swift EchoTests/PDFBlockPageMapperTests.swift EchoTests/PDFBlockPageCaptureTests.swift
git commit -m "feat(pdf): capture per-block source page index at import"
```

---

### Task 3: Page auto-follow + best-effort word overlay

**Files:** Create `EchoCore/Views/PDFReadAlongController.swift`; Modify `EchoCore/Views/PDFDocumentView.swift`.

Runtime-only — verified by build + the on-device checklist. No unit test (the resolver itself is already tested; this is wiring + PDFKit geometry).

- [ ] **Step 1: Read-along controller (resolver wiring)**

Create `EchoCore/Views/PDFReadAlongController.swift` — an `@Observable @MainActor` helper that loads the timeline + word caches once and resolves the active block/word for a time. Mirror `ReaderFeedViewModel`'s cache loads (`WordTimingDAO.words(forAudiobook:)` and the `timeline_item`⋈`epub_block` query) and call `ReaderActiveBlockResolver.activeBlockID(...)` + `.activeWord(...)`. Expose:

```swift
    func activeBlock(at time: TimeInterval) -> (blockID: String, wordIndex: Int?)?
    func pageIndex(forBlock blockID: String) -> Int?   // from PDFBlockPageDAO, cached
    func wordText(blockID: String, wordIndex: Int) -> String?  // from the block text via WordTokenizer
```

Load `PDFBlockPageDAO(db:).rows(for:)` into a `[blockID: pageIndex]` dictionary once.

- [ ] **Step 2: Drive the overlay from `PDFDocumentView`**

In `PDFDocumentView`, add `@State private var readAlong: PDFReadAlongController?` (built in the existing `.task` once the document/db are ready). Add `.onChange(of: model.currentPlaybackTime)`:

```swift
    .onChange(of: model.currentPlaybackTime) { _, t in
        guard let ra = readAlong, let active = ra.activeBlock(at: t) else { return }
        // Page auto-follow (robust):
        if let page = ra.pageIndex(forBlock: active.blockID) {
            activePageIndex = page          // bound into PDFKitView → go(to: page) when it changes
        }
        // Word highlight (best-effort): the term to search for on the page.
        activeWordTerm = active.wordIndex.flatMap { ra.wordText(blockID: active.blockID, wordIndex: $0) }
    }
```

Thread `activePageIndex: Int?` and `activeWordTerm: String?` into `PDFKitView` (new params). In the coordinator:
- **Auto-follow:** when `activePageIndex` changes and differs from `pdfView.currentPage`'s index, `pdfView.go(to: document.page(at: idx))` (guard against fighting a user scroll — only auto-follow while `model.isPlaying`).
- **Word highlight (best-effort):** when `activeWordTerm` changes, run `pdfView.document?.findString(term, withOptions: .caseInsensitive)` scoped to the active page (or `page.selection(for:)` around the term), take the first selection on that page, get `selection.bounds(for: page)`, convert via `pdfView.convert(bounds, from: page)`, and position a highlight `UIView`/`CALayer` (added once to the PDFView, 25%-alpha tint, matching the card-feed karaoke). Clear/hide it when no term or no match. Throttle to the existing karaoke cadence (~12 Hz). If the term yields multiple/zero matches, leave the page-follow as the only feedback.

> Document clearly in the report: the word highlight is best-effort search-based and needs on-device tuning; page auto-follow is the reliable behavior. Do NOT fight `PDFViewState` restore (only auto-follow on playback ticks while playing, not during user scroll/zoom).

- [ ] **Step 3: Build + commit**

Run: `"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests` → SUCCEEDED.

```bash
git add EchoCore/Views/PDFReadAlongController.swift EchoCore/Views/PDFDocumentView.swift
git commit -m "feat(pdf): page auto-follow + best-effort word highlight overlay"
```

---

### Task 4: Define-on-page (Look Up + Save via long-press)

**Files:** Modify `EchoCore/Views/PDFDocumentView.swift` (the `PDFKitView` long-press path).

Runtime-only — build + on-device.

- [ ] **Step 1: Resolve the word at the long-press point and offer actions**

The existing `Coordinator.handleLongPress` captures `PDFViewState` and triggers alignment options. Extend it: on `.began`, read the word at the touch point directly from the PDF —

```swift
    let location = gesture.location(in: pdfView)
    guard let page = pdfView.page(for: location, nearest: true) else { /* existing alignment path */ }
    let pagePoint = pdfView.convert(location, to: page)
    let term = page.selectionForWord(at: pagePoint)?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
```

When a non-empty `term` is found, surface a menu/confirmationDialog with **Look Up "<term>"** (if `DictionaryLookupPresenter.hasDefinition(for: term)` → `DictionaryLookupPresenter.present(term:)`), **Save "<term>"**, and the existing **Alignment options** entry (so alignment is not lost). When no word is found, keep today's behavior (alignment options directly).

- [ ] **Step 2: Save reuses M2**

"Save" mirrors M2's `saveVocabularyWord`: cap (`FreeTierGate.canCreateFlashcards(adding:1)` → paywall), dedupe (`FlashcardDAO.vocabularyCard(for:word:)`), build (`VocabularyCardBuilder.make`) with the audio time from the read-along controller's current active block (`ra.activeBlock(at: model.currentPlaybackTime)` → block start via the timeline cache; word-exact time is unavailable on the page, so block start is the honest anchor), context from the surrounding `page.selection` sentence, then `FlashcardDAO.insert`. Present the paywall via `model.paywallContext`/`model.showPaywall`.

> `page.selectionForWord(at:)` is `PDFPage.selectionForWord(at:)` (PDFKit). Use it for the word; widen to `selectionForLine(at:)` for the context sentence. Verify these PDFKit APIs compile on the iOS 18 SDK; if `selectionForWord` is unavailable, fall back to `page.selection(from:to:)` around the character index from `page.characterIndex(at:)`.

- [ ] **Step 3: Build + commit**

Run: `"$HOME/.claude/bin/xcode-build-gate.sh" --wait && make build-tests` → SUCCEEDED.

```bash
git add EchoCore/Views/PDFDocumentView.swift
git commit -m "feat(pdf): long-press define + save word on the PDF page"
```

---

## On-device verification (required before merge)

With a narrated PDF open in page mode, playing:
1. The page **auto-follows** narration (turns to the active block's page); user scroll/zoom is not fought while paused.
2. The active word is highlighted on the page (best-effort) — assess accuracy; acceptable fallback is page-level follow.
3. Long-press a word → **Look Up "<word>"** + **Save "<word>"** + existing Alignment options; Save creates a vocabulary card (cap + dedupe honored); no word found → alignment options as before.
4. Existing PDF behaviors intact: state restore, bottom action menu, manual alignment.
5. Re-import an existing PDF to populate `pdf_block_page` (older PDFs auto-follow by search only until re-imported).

## Out of scope for M3

- Exact per-word character-bbox highlighting (proven infeasible; best-effort search is the substitute).
- macOS PDF surface (none exists).
- Vocabulary review surfacing / narrate-PDF affordance (M4).

## Self-review notes

- **Spec coverage (M3 revised):** V26 `pdf_block_page` (T1) ✓; import page capture (T2) ✓; page auto-follow (T3) ✓; best-effort word highlight (T3, documented) ✓; define-on-page Look Up + Save (T4) ✓.
- **Verifiable vs deferred:** T1–T2 are unit-tested; T3–T4 are runtime (on-device checklist).
- **Type consistency:** `PDFBlockPageRecord`/`PDFBlockPageDAO` (T1) used by T2's capture + T3's `pageIndex(forBlock:)`; `PDFBlockPageMapper.map` (T2) signature matches its test; T4 reuses M2's `DictionaryLookupPresenter`/`VocabularyCardBuilder`/`FlashcardDAO.vocabularyCard`/`FreeTierGate`.
- **Migration safety:** V26 registered after V25; `schema-migration-reviewer` runs before the Task-1 commit.
