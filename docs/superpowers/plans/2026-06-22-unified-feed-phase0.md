# Unified Feed — Phase 0 Implementation Plan (Trust the Data)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Echo's data trustworthy for the unified feed before any UI is built: an *honest* "does this chapter have audio?" query, and a fix so excluded chapters stop generating flashcards.

**Architecture:** Two small, pure additions over the existing GRDB layer. (1) A new `AlignmentAnchorDAO.hasAnchor(for:anyOf:)` existence query + a `ChapterAudioStatusResolver` that asks "is ANY block in this chapter anchored to audio" (not just the heading block — anchors land on content, so a single-block lookup under-reports). (2) Add an `is_hidden` gate to `ChapterCardDrafter`'s heading query so hidden chapters don't get auto-drafted cards. No schema change, no UI.

**Tech Stack:** Swift, GRDB, Swift Testing (`@Test`/`#expect`).

**Spec:** [docs/superpowers/specs/2026-06-22-unified-feed-design.md](../specs/2026-06-22-unified-feed-design.md) §4 (honest `hasAudio`), §7.1 (flashcard gate), §12 (Phase 0).

## Global Constraints

- **Branch:** work on `feature/unified-feed` (already checked out; the spec commit `b826ff9` is its first commit). Commit each task here; do **not** push (protected-ladder; push/PR is a separate heads-up).
- **Testing framework:** Swift Testing — test types are plain `struct`s with `@Test` methods and `#expect(...)`. No XCTest.
- **DI pattern:** concrete types with `let db: DatabaseWriter`; tests use `DatabaseService(inMemory: ())` and pass `db.writer` into DAOs/resolvers. No singletons, no protocols.
- **Build/test loop:** build the test bundle once with `make build-tests`, then run one suite with `make test-only FILTER=EchoTests/<SuiteName>`. After editing source or tests, re-run `make build-tests` before `make test-only`. If `make build-tests` fails with an `onnxruntime` code-signing error under Xcode 26.5, append `CODE_SIGNING_ALLOWED=NO` (e.g. `make build-tests CODE_SIGNING_ALLOWED=NO`).
- **16 GB machine:** never enable parallel testing, never run two `xcodebuild` invocations at once.
- **SPDX header:** every new `.swift` file starts with line 1 exactly `// SPDX-License-Identifier: GPL-3.0-or-later`. A SwiftFormat PostToolUse hook reflows the whole file on edit and can push the SPDX line below an `import`; after any edit to a new file, confirm SPDX is still line 1.
- **No migration in Phase 0:** no new tables/columns; do not touch `Shared/Database/Migrations/` or `Schema_V*`.

---

## File Structure

| File | Responsibility |
|---|---|
| `Shared/Database/DAOs/AlignmentAnchorDAO.swift` (modify) | Add `hasAnchor(for:anyOf:)` — cheap boolean "is any of these blocks anchored?" |
| `Shared/Services/ChapterAudioStatusResolver.swift` (create) | Read model: `hasAudio(audiobookID:chapterIndex:)` over a chapter's whole block range |
| `Shared/Services/ChapterCardDrafter.swift` (modify) | Add `AND is_hidden = 0` to the heading query |
| `EchoTests/AlignmentAnchorExistsTests.swift` (create) | Tests for the new DAO method |
| `EchoTests/ChapterAudioStatusResolverTests.swift` (create) | Tests for the resolver, incl. the "anchor-on-content-not-heading" honesty test |
| `EchoTests/ChapterCardDrafterTests.swift` (modify) | Add the hidden-heading exclusion test |

---

## Task 1: `AlignmentAnchorDAO.hasAnchor(for:anyOf:)`

**Files:**
- Modify: `Shared/Database/DAOs/AlignmentAnchorDAO.swift` (add one method inside `struct AlignmentAnchorDAO`, after the existing `anchor(for:epubBlockID:)` method near line 75)
- Test: `EchoTests/AlignmentAnchorExistsTests.swift` (create)

**Interfaces:**
- Consumes: `DatabaseService(inMemory: ())`, `db.writer` (a `DatabaseWriter`), `AlignmentAnchorDAO(db:)`, `AlignmentAnchorRecord(id:audiobookID:epubBlockID:audioTime:audioEndTime:anchorKind:source:note:createdAt:modifiedAt:)`.
- Produces: `func hasAnchor(for audiobookID: String, anyOf epubBlockIDs: [String]) throws -> Bool` on `AlignmentAnchorDAO`. Returns `true` iff at least one anchor exists in `audiobookID` whose `epub_block_id` is in `epubBlockIDs`; `false` for an empty `epubBlockIDs`.

- [ ] **Step 1: Write the failing test**

Create `EchoTests/AlignmentAnchorExistsTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
import GRDB
@testable import Echo

struct AlignmentAnchorExistsTests {
    /// Audiobook `book-1` with three paragraph blocks: b-head, b-para, b-other.
    private func seed() throws -> DatabaseService {
        let db = try DatabaseService(inMemory: ())
        try db.write { db in
            try db.execute(sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book-1','Test',3600)")
            for (i, id) in ["b-head", "b-para", "b-other"].enumerated() {
                try db.execute(sql: """
                    INSERT INTO epub_block (id, audiobook_id, spine_href, spine_index, block_index, sequence_index, block_kind)
                    VALUES (?, 'book-1', 'c1.xhtml', 0, ?, ?, 'paragraph')
                    """, arguments: [id, i, i])
            }
        }
        return db
    }

    private func anchor(_ id: String, block: String, time: Double) -> AlignmentAnchorRecord {
        AlignmentAnchorRecord(
            id: id, audiobookID: "book-1", epubBlockID: block,
            audioTime: time, audioEndTime: nil, anchorKind: "point",
            source: "autoAlignment", note: nil, createdAt: nil, modifiedAt: nil
        )
    }

    @Test func returnsTrueWhenAnyGivenBlockHasAnchor() throws {
        let db = try seed()
        try AlignmentAnchorDAO(db: db.writer).insert(anchor("a1", block: "b-para", time: 12))
        let has = try AlignmentAnchorDAO(db: db.writer)
            .hasAnchor(for: "book-1", anyOf: ["b-head", "b-para"])
        #expect(has == true)
    }

    @Test func returnsFalseWhenNoGivenBlockHasAnchor() throws {
        let db = try seed()
        try AlignmentAnchorDAO(db: db.writer).insert(anchor("a1", block: "b-other", time: 5))
        let has = try AlignmentAnchorDAO(db: db.writer)
            .hasAnchor(for: "book-1", anyOf: ["b-head", "b-para"])
        #expect(has == false)
    }

    @Test func returnsFalseForEmptyBlockList() throws {
        let db = try seed()
        let has = try AlignmentAnchorDAO(db: db.writer)
            .hasAnchor(for: "book-1", anyOf: [])
        #expect(has == false)
    }
}
```

- [ ] **Step 2: Run the test, verify it fails to compile**

Run: `make build-tests`
Expected: FAIL — `value of type 'AlignmentAnchorDAO' has no member 'hasAnchor'`.

- [ ] **Step 3: Implement the method**

In `Shared/Database/DAOs/AlignmentAnchorDAO.swift`, add this method inside `struct AlignmentAnchorDAO`, right after the existing `anchor(for:epubBlockID:)` method:

```swift
    /// Whether any anchor exists for `audiobookID` on any of `epubBlockIDs`.
    /// Used to answer "does this chapter have audio?" over a whole block range,
    /// since anchors usually land on content blocks rather than the heading block.
    func hasAnchor(for audiobookID: String, anyOf epubBlockIDs: [String]) throws -> Bool {
        guard !epubBlockIDs.isEmpty else { return false }
        return try db.read { db in
            try AlignmentAnchorRecord
                .filter(Column("audiobook_id") == audiobookID)
                .filter(epubBlockIDs.contains(Column("epub_block_id")))
                .limit(1)
                .fetchOne(db) != nil
        }
    }
```

(`epubBlockIDs.contains(Column("epub_block_id"))` compiles to a SQL `epub_block_id IN (...)`. `.limit(1).fetchOne(db) != nil` avoids loading more than one row.)

After saving, confirm the SPDX line is still line 1 of the file (the format hook may have reflowed it — it should not have moved, but verify).

- [ ] **Step 4: Run the test, verify it passes**

Run: `make build-tests && make test-only FILTER=EchoTests/AlignmentAnchorExistsTests`
Expected: PASS — 3 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Shared/Database/DAOs/AlignmentAnchorDAO.swift EchoTests/AlignmentAnchorExistsTests.swift
git commit -m "feat(alignment): add AlignmentAnchorDAO.hasAnchor(for:anyOf:) existence query"
```

---

## Task 2: `ChapterAudioStatusResolver`

**Files:**
- Create: `Shared/Services/ChapterAudioStatusResolver.swift`
- Test: `EchoTests/ChapterAudioStatusResolverTests.swift` (create)

**Interfaces:**
- Consumes: `AlignmentAnchorDAO.hasAnchor(for:anyOf:)` (Task 1); `EPubBlockDAO(db:)` with `func blocks(for audiobookID: String, chapterIndex: Int) throws -> [EPubBlockRecord]` (returns blocks ordered by `sequence_index`); `EPubBlockRecord.id` (`String`).
- Produces: `struct ChapterAudioStatusResolver { let db: DatabaseWriter; func hasAudio(audiobookID: String, chapterIndex: Int) throws -> Bool }`. Returns `true` iff any block with `chapter_index == chapterIndex` has an alignment anchor; `false` when the chapter has no blocks.

- [ ] **Step 1: Write the failing test**

Create `EchoTests/ChapterAudioStatusResolverTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
import GRDB
@testable import Echo

struct ChapterAudioStatusResolverTests {
    /// `book-1`: chapter 0 = heading `ch0-head` + paragraph `ch0-para`;
    /// chapter 1 = heading `ch1-head` only. No anchors seeded here.
    private func seed() throws -> DatabaseService {
        let db = try DatabaseService(inMemory: ())
        try db.write { db in
            try db.execute(sql: "INSERT INTO audiobook (id, title, duration) VALUES ('book-1','Test',3600)")
            try db.execute(sql: """
                INSERT INTO epub_block (id, audiobook_id, spine_href, spine_index, block_index, sequence_index, block_kind, chapter_index)
                VALUES ('ch0-head', 'book-1', 'c1.xhtml', 0, 0, 0, 'heading', 0)
                """)
            try db.execute(sql: """
                INSERT INTO epub_block (id, audiobook_id, spine_href, spine_index, block_index, sequence_index, block_kind, chapter_index)
                VALUES ('ch0-para', 'book-1', 'c1.xhtml', 0, 1, 1, 'paragraph', 0)
                """)
            try db.execute(sql: """
                INSERT INTO epub_block (id, audiobook_id, spine_href, spine_index, block_index, sequence_index, block_kind, chapter_index)
                VALUES ('ch1-head', 'book-1', 'c2.xhtml', 1, 0, 2, 'heading', 1)
                """)
        }
        return db
    }

    private func insertAnchor(_ db: DatabaseService, block: String) throws {
        try AlignmentAnchorDAO(db: db.writer).insert(
            AlignmentAnchorRecord(
                id: "a-\(block)", audiobookID: "book-1", epubBlockID: block,
                audioTime: 30, audioEndTime: nil, anchorKind: "point",
                source: "autoAlignment", note: nil, createdAt: nil, modifiedAt: nil
            )
        )
    }

    /// The honesty test: the anchor is on the CONTENT block (`ch0-para`), not the
    /// heading. hasAudio for chapter 0 must STILL be true.
    @Test func hasAudioTrueWhenAnchorOnContentBlockNotHeading() throws {
        let db = try seed()
        try insertAnchor(db, block: "ch0-para")
        let resolver = ChapterAudioStatusResolver(db: db.writer)
        #expect(try resolver.hasAudio(audiobookID: "book-1", chapterIndex: 0) == true)
    }

    @Test func hasAudioFalseWhenChapterHasNoAnchors() throws {
        let db = try seed()
        try insertAnchor(db, block: "ch0-para") // chapter 0 only; chapter 1 has none
        let resolver = ChapterAudioStatusResolver(db: db.writer)
        #expect(try resolver.hasAudio(audiobookID: "book-1", chapterIndex: 1) == false)
    }

    @Test func hasAudioFalseWhenChapterHasNoBlocks() throws {
        let db = try seed()
        let resolver = ChapterAudioStatusResolver(db: db.writer)
        #expect(try resolver.hasAudio(audiobookID: "book-1", chapterIndex: 99) == false)
    }
}
```

- [ ] **Step 2: Run the test, verify it fails to compile**

Run: `make build-tests`
Expected: FAIL — `cannot find 'ChapterAudioStatusResolver' in scope`.

- [ ] **Step 3: Create the resolver**

Create `Shared/Services/ChapterAudioStatusResolver.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

/// Read model for the unified feed: answers "does this audio chapter have any
/// aligned audio?" honestly.
///
/// Why a range test and not a single lookup: the auto-alignment pipeline places
/// anchors on the content blocks it can match (paragraphs/sentences), which are
/// usually NOT the chapter's heading block. Testing only the heading block would
/// report a fully-aligned chapter as "no audio". So we test whether ANY block
/// whose `chapter_index` equals `chapterIndex` carries an anchor.
struct ChapterAudioStatusResolver {
    let db: DatabaseWriter

    /// True if any block in `chapterIndex` (for `audiobookID`) has an alignment
    /// anchor. False when the chapter has no blocks (e.g. front matter / unknown).
    func hasAudio(audiobookID: String, chapterIndex: Int) throws -> Bool {
        let blockIDs = try EPubBlockDAO(db: db)
            .blocks(for: audiobookID, chapterIndex: chapterIndex)
            .map(\.id)
        guard !blockIDs.isEmpty else { return false }
        return try AlignmentAnchorDAO(db: db)
            .hasAnchor(for: audiobookID, anyOf: blockIDs)
    }
}
```

Confirm SPDX is line 1 after saving.

- [ ] **Step 4: Run the test, verify it passes**

Run: `make build-tests && make test-only FILTER=EchoTests/ChapterAudioStatusResolverTests`
Expected: PASS — 3 tests pass, including `hasAudioTrueWhenAnchorOnContentBlockNotHeading`.

- [ ] **Step 5: Commit**

```bash
git add Shared/Services/ChapterAudioStatusResolver.swift EchoTests/ChapterAudioStatusResolverTests.swift
git commit -m "feat(feed): add ChapterAudioStatusResolver for honest per-chapter hasAudio"
```

---

## Task 3: Gate flashcard drafting on `is_hidden`

**Files:**
- Modify: `Shared/Services/ChapterCardDrafter.swift` (the heading SQL, lines 34–41)
- Test: `EchoTests/ChapterCardDrafterTests.swift` (add one `@Test` method; the file's `makeDB()` helper already creates `epub_block` with an `is_hidden` column defaulting to `false`)

**Interfaces:**
- Consumes: existing `ChapterCardDrafterTests.makeDB()` and `drafter.draftCards(for:bookTitle:db:)` (returns `Int` — number of cards created).
- Produces: behavior change only — headings with `is_hidden = 1` are no longer drafted.

- [ ] **Step 1: Write the failing test**

In `EchoTests/ChapterCardDrafterTests.swift`, add this method immediately after the `skipsFrontMatter()` test (after its closing brace near line 98):

```swift
    @Test func skipsHiddenHeadings() async throws {
        let db = try await makeDB()
        let bookID = "test-book-hidden"
        try await db.write { db in
            try db.execute(sql: "INSERT INTO audiobook (id, title) VALUES (?, ?)", arguments: [bookID, "Test"])
            try db.execute(sql: """
                INSERT INTO epub_block (id, audiobook_id, text, block_kind, chapter_index, sequence_index, is_front_matter, is_hidden)
                VALUES ('h0', ?, 'Visible Chapter', 'heading', 0, 0, 0, 0)
                """, arguments: [bookID])
            try db.execute(sql: """
                INSERT INTO epub_block (id, audiobook_id, text, block_kind, chapter_index, sequence_index, is_front_matter, is_hidden)
                VALUES ('h1', ?, 'Hidden Chapter', 'heading', 1, 1, 0, 1)
                """, arguments: [bookID])
        }

        let count = try await drafter.draftCards(for: bookID, bookTitle: "Test", db: db)
        #expect(count == 1) // only the visible heading is drafted
    }
```

- [ ] **Step 2: Run the test, verify it fails**

Run: `make build-tests && make test-only FILTER=EchoTests/ChapterCardDrafterTests`
Expected: FAIL — `skipsHiddenHeadings` reports `count == 2` (the hidden heading is still drafted because the query has no `is_hidden` filter). The other five `ChapterCardDrafterTests` pass.

- [ ] **Step 3: Add the `is_hidden` gate**

In `Shared/Services/ChapterCardDrafter.swift`, change the heading query (inside `draftCards`, the `Row.fetchAll` SQL) from:

```swift
                try Row.fetchAll(db, sql: """
                    SELECT id, text, chapter_index
                    FROM epub_block
                    WHERE audiobook_id = ?
                      AND block_kind = 'heading'
                      AND is_front_matter = 0
                    ORDER BY sequence_index
                    """, arguments: [audiobookID])
```

to:

```swift
                try Row.fetchAll(db, sql: """
                    SELECT id, text, chapter_index
                    FROM epub_block
                    WHERE audiobook_id = ?
                      AND block_kind = 'heading'
                      AND is_front_matter = 0
                      AND is_hidden = 0
                    ORDER BY sequence_index
                    """, arguments: [audiobookID])
```

- [ ] **Step 4: Run the test, verify it passes**

Run: `make build-tests && make test-only FILTER=EchoTests/ChapterCardDrafterTests`
Expected: PASS — all six tests pass, including `skipsHiddenHeadings` (`count == 1`).

- [ ] **Step 5: Commit**

```bash
git add Shared/Services/ChapterCardDrafter.swift EchoTests/ChapterCardDrafterTests.swift
git commit -m "fix(study): exclude hidden chapters from auto-drafted flashcards"
```

---

## Phase 0 Done — Verification

- [ ] **Run all three suites together** to confirm no regressions:

```
make build-tests && make test-only FILTER=EchoTests/AlignmentAnchorExistsTests
make test-only FILTER=EchoTests/ChapterAudioStatusResolverTests
make test-only FILTER=EchoTests/ChapterCardDrafterTests
```

Expected: all pass.

- [ ] Confirm three commits exist on `feature/unified-feed`:

```bash
git log --oneline -3
```

Expected: the three Task commits above, on top of `b826ff9` (spec).

**Notes / out of scope for Phase 0:**
- No production caller wires `ChapterCardDrafter` today; the gate is correct regardless and is consumed when Phase 2 adds the per-heading off-menu. No new caller is added here (YAGNI).
- `ChapterAudioStatusResolver` is the substrate Phase 1's feed will consume to style "has audio / no audio" rows; it ships now, unused, with tests.
- No doc-sync needed yet — these are internal correctness changes with no user-visible surface until the feed UI lands. ARCHITECTURE.md / CHANGELOG updates are deferred to the phase that ships the visible feature.
- The chapter-level `hasAudio` is the Phase-0 primitive. If Phase 1 needs finer per-heading granularity (multiple top-level headings inside one `chapter_index`), extend with a `sequence_index`-window variant then — do not build it now.
