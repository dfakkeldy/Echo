# Word-Level Alignment, Karaoke, macOS Batch Queue & M4B Chapter Export — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add word-level read-along timings, karaoke (word-by-word) highlighting in the EPUB reader on iOS *and* macOS, a persistent macOS batch processing queue (import → transcribe → align, survives restart), and real m4b chapter markers via the `swift-audio-marker` package.

**Architecture:** Four independent phases on top of `main` (post-PR #77). **Phase A** persists per-word timings in a new `word_timing` table, materialized by char-proportional interpolation anchored to the real block-level anchor times the pipeline already computes, with an optional DTW-derived refinement layer. **Phase B** consumes those timings to highlight the active word in both readers (iOS UIKit cells + macOS SwiftUI cards) via the already-shared `ReaderActiveBlockResolver`. **Phase C** turns the in-memory, align-only `MacBulkAlignmentService` into a DB-backed queue running the full per-book pipeline. **Phase D** swaps the copy-only `AudioMarker` stub for the real `swift-audio-marker` engine.

**Tech Stack:** Swift 6, SwiftUI, UIKit (iOS reader cells), AppKit (macOS), AVFoundation, GRDB, WhisperKit, `swift-audio-marker` (new SPM dep). Tests use **Swift Testing** (`@Test`/`#expect`), DB tests use `DatabaseService(inMemory: ())`.

---

## What changed since the stale plan (why this is a rewrite, not a patch)

This plan replaces the version written against PR #76. PR #77 ("BookPlayer redesign") shipped and **inverted the old Phase A**. The decisions baked into this rewrite:

- **macOS player convergence is DROPPED.** PR #77 deliberately built a *native* macOS player (`MacPlayerModel`, 783 lines, `AVPlayer` + `MTAudioProcessingTap` boost, chapter axis, 3-way loop, `MacSettingsView`). All iOS player views are excluded from the macOS target. Deleting `MacPlayerModel` to "converge" would reverse merged work and re-risk the just-validated Mac audio path. The macOS player is treated as **done**; new features target the existing `MacPlayerModel` / `MacReaderFeedView`.
- **Schema is at V18.** Next free versions: **V19** (word timings), **V20** (batch queue). (The old plan's V19/V20 numbers happen to still be correct.)
- **DAOs are instantiated directly** (`SomeDAO(db: writer)`) — there are **no** `databaseService.someDAO` accessors. The old plan assumed accessors; this one follows the real pattern (`AlignmentAnchorDAO`).
- **Migrations are bare enums** (`enum Schema_VNN { nonisolated static func migrate(_:) }`), registered manually in `DatabaseService.runMigrations`. There is no `Migration` protocol.
- **Word timings are interpolation-first, DTW-refined.** DTW emits *normalized-token* matches (numbers→words, sub-2-char tokens dropped), which do not map 1:1 to rendered words — so the robust foundation is char-proportional interpolation between real block anchors, with DTW times layered on as a refinement (Task A4).
- **m4b export is iOS-only** (narration is `#if os(iOS)`; macOS excludes the Narration folder). The old plan's macOS export menu item is dropped.
- **Karaoke is two implementations** (iOS UIKit cells + macOS SwiftUI `MacBlockCardView`) because the readers do not share view code — but they *do* share `ReaderActiveBlockResolver` and the DB, so the data layer is written once.

Each phase is independently shippable and can be merged on its own branch.

---

## File Structure Map

| File | Phase | Create/Modify | Role |
|------|-------|---------------|------|
| `Shared/Database/WordTimingRecord.swift` | A | Create | One rendered word → audio `[start,end)` for a block |
| `Shared/Database/DAOs/WordTimingDAO.swift` | A | Create | CRUD for `word_timing` |
| `Shared/Database/Migrations/Schema_V19.swift` | A | Create | `word_timing` table + indexes |
| `Shared/Database/DatabaseService.swift` | A, C | Modify | Register V19 + V20 |
| `Shared/WordTimingInterpolator.swift` | A | Create | Pure: block text + `[start,end)` → per-word ranges |
| `EchoCore/Services/WordTimingMaterializer.swift` | A | Create | Reads block timeline, writes `word_timing` rows |
| `EchoCore/Services/TokenDTW.swift` | A | Modify | Expose per-token `wordMatches` (refinement) |
| `EchoCore/Services/WordTimingRefiner.swift` | A | Create | Pure: override interpolated times with DTW token times |
| `EchoCore/Services/AutoAlignmentService.swift` | A | Modify | Call materializer (+ refiner) after recalculate |
| `EchoCore/Services/AlignmentService.swift` | A | Modify | Call materializer after manual recalculate |
| `Shared/ReaderActiveBlockResolver.swift` | B | Modify | Add pure `activeWord(in:time:activeBlockID:)` |
| `EchoCore/ViewModels/ReaderFeedViewModel.swift` | B | Modify | Load word cache; publish active word |
| `EchoCore/Views/Cells/ParagraphCardCell.swift` | B | Modify | Word highlight via stored `[NSRange]` |
| `EchoCore/Views/Cells/HeadingCardCell.swift` | B | Modify | Word highlight via stored `[NSRange]` |
| `EchoCore/Views/ReaderFeedCollectionView.swift` | B | Modify | Push active word to active cell (throttled) |
| `EchoCore/Views/ReaderTab.swift` | B | Modify | Observe active word |
| `Echo macOS/Views/MacReaderFeedView.swift` | B | Modify | Load word cache; faster word tick; highlight |
| `Shared/Database/BatchQueueRecord.swift` | C | Create | Persistent queue item |
| `Shared/Database/DAOs/BatchQueueDAO.swift` | C | Create | CRUD + claim-next + restart recovery |
| `Shared/Database/Migrations/Schema_V20.swift` | C | Create | `batch_queue` table |
| `Shared/BatchQueueRunner.swift` | C | Create | Testable sequential queue engine (injected stages) |
| `Echo macOS/Services/MacBatchProcessingService.swift` | C | Create | macOS `@Observable` wrapper supplying real stages |
| `Echo macOS/Services/MacBulkAlignmentService.swift` | C | Modify | Folder scan → enqueue items |
| `Echo macOS/Views/MacBatchQueueView.swift` | C | Create | Queue management UI + row |
| `Echo macOS/Echo_macOSApp.swift` | C | Modify | Wire service, menu, restart recovery |
| `Echo.xcodeproj/project.pbxproj` | D | Modify | Add `swift-audio-marker` SPM dep (Echo iOS target) |
| `EchoCore/Services/Narration/AudioMarkerStub.swift` | D | Modify | Replace stub body with real engine call |
| `EchoCore/Services/Narration/NarrationExportService.swift` | D | Modify | Real chapter titles; `await` writer |
| `EchoCore/Views/ExportProgressView.swift` | D | Create (if missing) | iOS export progress + share |
| `EchoCore/Views/NowPlayingTab.swift` | D | Modify (if needed) | Export entry point |

---

## Phase A: Word-Level Read-Along Timings

> **Outcome:** every aligned block gains per-word `[start,end)` rows in a new `word_timing` table, cleared and rebuilt on each (re)alignment. A1–A3 deliver working word timings via robust interpolation. A4 layers DTW accuracy on top and can be deferred without breaking karaoke.

### Task A1: `word_timing` schema, record, DAO

**Files:**
- Create: `Shared/Database/WordTimingRecord.swift`
- Create: `Shared/Database/DAOs/WordTimingDAO.swift`
- Create: `Shared/Database/Migrations/Schema_V19.swift`
- Modify: `Shared/Database/DatabaseService.swift:110` (register migration)
- Test: `EchoTests/WordTimingDAOTests.swift`

- [ ] **Step 1: Write the failing DAO test**

```swift
// EchoTests/WordTimingDAOTests.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Echo

struct WordTimingDAOTests {
    @Test func insertAndFetchByBlockOrdersByWordIndex() throws {
        let db = try DatabaseService(inMemory: ())
        let dao = WordTimingDAO(db: db.writer)
        try dao.insert([
            WordTimingRecord(audiobookID: "bk", epubBlockID: "b1", wordIndex: 1,
                             word: "world", audioStartTime: 1.0, audioEndTime: 1.5,
                             confidence: 0.5, source: "interpolated"),
            WordTimingRecord(audiobookID: "bk", epubBlockID: "b1", wordIndex: 0,
                             word: "hello", audioStartTime: 0.0, audioEndTime: 1.0,
                             confidence: 0.5, source: "interpolated"),
        ])
        let words = try dao.words(forAudiobook: "bk", blockID: "b1")
        #expect(words.map(\.word) == ["hello", "world"])
        #expect(words.map(\.wordIndex) == [0, 1])
    }

    @Test func deleteAllRemovesOnlyThatBook() throws {
        let db = try DatabaseService(inMemory: ())
        let dao = WordTimingDAO(db: db.writer)
        try dao.insert([
            WordTimingRecord(audiobookID: "bk", epubBlockID: "b1", wordIndex: 0,
                             word: "x", audioStartTime: 0, audioEndTime: 1,
                             confidence: 0.5, source: "interpolated"),
            WordTimingRecord(audiobookID: "other", epubBlockID: "b1", wordIndex: 0,
                             word: "y", audioStartTime: 0, audioEndTime: 1,
                             confidence: 0.5, source: "interpolated"),
        ])
        try dao.deleteAll(forAudiobook: "bk")
        #expect(try dao.words(forAudiobook: "bk").isEmpty)
        #expect(try dao.words(forAudiobook: "other").count == 1)
    }
}
```

> **Note:** `DatabaseService.writer` is the `DatabaseWriter`. Confirm its access level — it is used by DAOs throughout (`AlignmentAnchorDAO.db`). If `writer` is `private`, expose it the same way other DAOs receive it (the existing code passes `db.writer` into DAOs; if not visible from tests, add an `internal` accessor mirroring how `AlignmentService` obtains its writer).

- [ ] **Step 2: Run the test to verify it fails to compile**

Run: `make build-tests`
Expected: FAIL — `WordTimingRecord` / `WordTimingDAO` undefined.

- [ ] **Step 3: Create `WordTimingRecord`**

```swift
// Shared/Database/WordTimingRecord.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

/// One rendered word within an EPUB block mapped to its audio `[start, end)`.
/// Materialized by `WordTimingMaterializer` on every (re)alignment. Rendered-word
/// granularity (whitespace split of the block's plain text), not normalized DTW
/// tokens — so the reader can index it directly by word position.
struct WordTimingRecord: Identifiable, Equatable, Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var audiobookID: String
    var epubBlockID: String
    /// Zero-based index of this word within the block's whitespace-split plain text.
    var wordIndex: Int
    /// The rendered word (denormalized for debugging/inspection).
    var word: String
    var audioStartTime: TimeInterval
    var audioEndTime: TimeInterval
    /// 0.0–1.0. Interpolated words get a fixed medium value; DTW-refined words higher.
    var confidence: Double
    /// "interpolated" or "dtw".
    var source: String

    static let databaseTableName = "word_timing"

    enum CodingKeys: String, CodingKey {
        case id
        case audiobookID = "audiobook_id"
        case epubBlockID = "epub_block_id"
        case wordIndex = "word_index"
        case word
        case audioStartTime = "audio_start_time"
        case audioEndTime = "audio_end_time"
        case confidence
        case source
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
```

- [ ] **Step 4: Create `WordTimingDAO`** (mirror `AlignmentAnchorDAO`'s `let db: DatabaseWriter` style)

```swift
// Shared/Database/DAOs/WordTimingDAO.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

/// DAO for per-word read-along timings.
struct WordTimingDAO {
    let db: DatabaseWriter

    func insert(_ records: [WordTimingRecord]) throws {
        guard !records.isEmpty else { return }
        try db.write { db in
            for record in records {
                var mutable = record
                try mutable.insert(db)
            }
        }
    }

    /// All words for a book, ordered by audio time (reader cache order).
    func words(forAudiobook audiobookID: String) throws -> [WordTimingRecord] {
        try db.read { db in
            try WordTimingRecord
                .filter(Column("audiobook_id") == audiobookID)
                .order(Column("audio_start_time"))
                .fetchAll(db)
        }
    }

    /// Words for one block, ordered by word index.
    func words(forAudiobook audiobookID: String, blockID: String) throws -> [WordTimingRecord] {
        try db.read { db in
            try WordTimingRecord
                .filter(Column("audiobook_id") == audiobookID)
                .filter(Column("epub_block_id") == blockID)
                .order(Column("word_index"))
                .fetchAll(db)
        }
    }

    @discardableResult
    func deleteAll(forAudiobook audiobookID: String) throws -> Int {
        try db.write { db in
            try WordTimingRecord
                .filter(Column("audiobook_id") == audiobookID)
                .deleteAll(db)
        }
    }
}
```

- [ ] **Step 5: Create `Schema_V19`** (bare-enum pattern, matching `Schema_V18`)

```swift
// Shared/Database/Migrations/Schema_V19.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

/// V19 — per-word read-along timings for karaoke highlighting.
enum Schema_V19 {
    nonisolated static func migrate(_ db: Database) throws {
        try db.create(table: "word_timing") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("audiobook_id", .text).notNull().indexed()
            t.column("epub_block_id", .text).notNull()
            t.column("word_index", .integer).notNull()
            t.column("word", .text).notNull()
            t.column("audio_start_time", .double).notNull()
            t.column("audio_end_time", .double).notNull()
            t.column("confidence", .double).notNull().defaults(to: 0.5)
            t.column("source", .text).notNull().defaults(to: "interpolated")
        }
        // Reader loads the whole book ordered by time; per-block lookups during refine.
        try db.create(
            index: "idx_word_timing_book_block",
            on: "word_timing",
            columns: ["audiobook_id", "epub_block_id", "word_index"])
    }
}
```

- [ ] **Step 6: Register the migration** in `DatabaseService.runMigrations` after the V18 line (`Shared/Database/DatabaseService.swift:110`)

```swift
        migrator.registerMigration("v18_abs_server") { db in try Schema_V18.migrate(db) }
        migrator.registerMigration("v19_word_timing") { db in try Schema_V19.migrate(db) }  // ← add
        try migrator.migrate(writer)
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `make build-tests && make test-only FILTER=EchoTests/WordTimingDAOTests`
Expected: PASS (both tests).

- [ ] **Step 8: Schema review + commit**

Run the `schema-migration-reviewer` agent (CLAUDE.md mandate) on the new migration before committing; confirm no version collision and that V19 is additive (no re-import required). Then:

```bash
git add Shared/Database/WordTimingRecord.swift Shared/Database/DAOs/WordTimingDAO.swift \
        Shared/Database/Migrations/Schema_V19.swift Shared/Database/DatabaseService.swift \
        EchoTests/WordTimingDAOTests.swift
git commit -m "feat(db): add word_timing table, record, and DAO (Schema V19)"
```

> **SwiftFormat hook:** after edits, verify the `// SPDX-License-Identifier` line is still line 1 of each file (the PostToolUse formatter can reflow it below an import).

---

### Task A2: `WordTimingInterpolator` (pure)

**Files:**
- Create: `Shared/WordTimingInterpolator.swift`
- Test: `EchoTests/WordTimingInterpolatorTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// EchoTests/WordTimingInterpolatorTests.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Echo  // Shared/EchoCore sources compile into the Echo app module

struct WordTimingInterpolatorTests {
    @Test func splitsWordsProportionallyByCharacterLength() {
        // "ab cde" → "ab"(2) + space + "cde"(3); 5 weighted chars over [0,10).
        let words = WordTimingInterpolator.interpolate(
            text: "ab cde", blockStart: 0, blockEnd: 10)
        #expect(words.count == 2)
        #expect(words[0].index == 0 && words[0].word == "ab")
        #expect(abs(words[0].start - 0.0) < 0.001)
        // "ab" + trailing space = 3 weight of 6 total → ends at 5.0
        #expect(abs(words[0].end - 5.0) < 0.001)
        #expect(words[1].word == "cde")
        #expect(abs(words[1].start - 5.0) < 0.001)
        #expect(abs(words[1].end - 10.0) < 0.001)
    }

    @Test func emptyTextProducesNoWords() {
        #expect(WordTimingInterpolator.interpolate(text: "   ", blockStart: 0, blockEnd: 5).isEmpty)
    }

    @Test func monotonicNonOverlappingTimes() {
        let words = WordTimingInterpolator.interpolate(
            text: "the quick brown fox", blockStart: 2, blockEnd: 6)
        for i in 1..<words.count {
            #expect(words[i].start >= words[i - 1].end - 0.0001)
        }
        #expect(words.first!.start >= 2)
        #expect(words.last!.end <= 6.0001)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `make build-tests`
Expected: FAIL — `WordTimingInterpolator` undefined.

- [ ] **Step 3: Implement the interpolator**

```swift
// Shared/WordTimingInterpolator.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Distributes a block's rendered words across `[blockStart, blockEnd)` by
/// character weight (word length + 1 for the following space). Pure and
/// dependency-free so it lives in `Shared/` and is unit-testable in isolation.
///
/// This is the robust read-along foundation: it needs only the block's real
/// start/end times (which the alignment pipeline already produces), not any
/// per-word audio data. `WordTimingRefiner` (Task A4) optionally overrides
/// individual word times with DTW-derived audio timestamps.
enum WordTimingInterpolator {
    struct Word: Equatable {
        let index: Int
        let word: String
        let start: TimeInterval
        let end: TimeInterval
    }

    /// - Parameters:
    ///   - text: the block's plain text (already newline-collapsed by the caller).
    ///   - blockStart: audio time the block begins.
    ///   - blockEnd: audio time the block ends (next block's start, or an estimate).
    static func interpolate(text: String, blockStart: TimeInterval, blockEnd: TimeInterval) -> [Word] {
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .map(String.init)
        guard !words.isEmpty else { return [] }

        let span = max(0, blockEnd - blockStart)
        // Weight each word by its length + 1 (trailing space) so longer words
        // get proportionally more time.
        let weights = words.map { Double($0.count + 1) }
        let total = max(1, weights.reduce(0, +))

        var result: [Word] = []
        var cursor: Double = 0
        for (i, word) in words.enumerated() {
            let start = blockStart + (cursor / total) * span
            cursor += weights[i]
            let end = blockStart + (cursor / total) * span
            result.append(Word(index: i, word: word, start: start, end: end))
        }
        return result
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `make test-only FILTER=EchoTests/WordTimingInterpolatorTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Shared/WordTimingInterpolator.swift EchoTests/WordTimingInterpolatorTests.swift
git commit -m "feat(align): add pure WordTimingInterpolator for read-along word ranges"
```

---

### Task A3: `WordTimingMaterializer` + wire into alignment

**Files:**
- Create: `EchoCore/Services/WordTimingMaterializer.swift`
- Modify: `EchoCore/Services/AlignmentService.swift` (call after `recalculateTimeline`)
- Modify: `EchoCore/Services/AutoAlignmentService.swift` (call after recalculate)
- Test: `EchoTests/WordTimingMaterializerTests.swift`

- [ ] **Step 1: Write the failing integration test**

```swift
// EchoTests/WordTimingMaterializerTests.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing
@testable import Echo

struct WordTimingMaterializerTests {
    /// Seeds two aligned blocks in timeline_item and expects word rows spanning
    /// each block's [start, nextStart).
    @Test func materializesWordsBetweenBlockAnchors() throws {
        let db = try DatabaseService(inMemory: ())
        try db.write { db in
            // epub_block rows so block text is available
            try db.execute(sql: """
                INSERT INTO epub_block (id, audiobook_id, sequence_index, block_kind, text, is_hidden)
                VALUES ('b0','bk',0,'paragraph','one two', 0),
                       ('b1','bk',1,'paragraph','three', 0)
                """)
            // timeline_item block-level rows with real start times
            try db.execute(sql: """
                INSERT INTO timeline_item
                  (id, audiobook_id, item_type, title, audio_start_time, audio_end_time,
                   granularity_level, is_enabled, epub_block_id)
                VALUES ('t0','bk','textSegment','', 0.0, 10.0, 1, 1, 'b0'),
                       ('t1','bk','textSegment','', 10.0, 14.0, 1, 1, 'b1')
                """)
        }
        try WordTimingMaterializer.materialize(audiobookID: "bk", writer: db.writer)

        let dao = WordTimingDAO(db: db.writer)
        let b0 = try dao.words(forAudiobook: "bk", blockID: "b0")
        #expect(b0.map(\.word) == ["one", "two"])
        #expect(abs(b0[0].start - 0.0) < 0.01)
        #expect(b0.last!.end <= 10.01)

        let b1 = try dao.words(forAudiobook: "bk", blockID: "b1")
        #expect(b1.map(\.word) == ["three"])
        #expect(b1[0].start >= 10.0)
    }

    @Test func reRunClearsPriorRows() throws {
        let db = try DatabaseService(inMemory: ())
        try db.write { db in
            try db.execute(sql: """
                INSERT INTO epub_block (id, audiobook_id, sequence_index, block_kind, text, is_hidden)
                VALUES ('b0','bk',0,'paragraph','hello world', 0)
                """)
            try db.execute(sql: """
                INSERT INTO timeline_item
                  (id, audiobook_id, item_type, title, audio_start_time, audio_end_time,
                   granularity_level, is_enabled, epub_block_id)
                VALUES ('t0','bk','textSegment','', 0.0, 4.0, 1, 1, 'b0')
                """)
        }
        try WordTimingMaterializer.materialize(audiobookID: "bk", writer: db.writer)
        try WordTimingMaterializer.materialize(audiobookID: "bk", writer: db.writer)
        #expect(try WordTimingDAO(db: db.writer).words(forAudiobook: "bk").count == 2)
    }
}
```

> **Note:** verify the real `epub_block` / `timeline_item` column names against `Schema_V4`/`Schema_V5` before running (e.g. `block_kind` vs `kind`, `is_hidden` presence). Adjust the seed SQL to match — the test is the contract, the column names must be exact.

- [ ] **Step 2: Run to verify failure**

Run: `make build-tests`
Expected: FAIL — `WordTimingMaterializer` undefined.

- [ ] **Step 3: Implement the materializer**

```swift
// EchoCore/Services/WordTimingMaterializer.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

/// Rebuilds the `word_timing` table for one audiobook from its block-level
/// timeline. Runs AFTER `AlignmentService.recalculateTimeline` so it sees the
/// final per-block `audio_start_time`s. Clears prior rows first, so each
/// (re)alignment converges (mirrors `AlignmentAnchorDAO.deleteAutoPipelineAnchors`).
enum WordTimingMaterializer {
    /// One aligned block: its text and start time, ordered by start.
    private struct Block {
        let id: String
        let text: String
        let start: TimeInterval
        let end: TimeInterval?
    }

    static func materialize(audiobookID: String, writer: DatabaseWriter) throws {
        let dao = WordTimingDAO(db: writer)
        try dao.deleteAll(forAudiobook: audiobookID)

        // Aligned, text-bearing blocks ordered by audio time. audio_start_time < 0
        // is the "unaligned" sentinel — skip those.
        let blocks: [Block] = try writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT ti.epub_block_id AS id,
                       eb.text AS text,
                       ti.audio_start_time AS start,
                       ti.audio_end_time AS end
                FROM timeline_item ti
                JOIN epub_block eb ON eb.id = ti.epub_block_id
                WHERE ti.audiobook_id = ?
                  AND ti.epub_block_id IS NOT NULL
                  AND ti.audio_start_time >= 0
                  AND eb.text IS NOT NULL AND eb.text <> ''
                ORDER BY ti.audio_start_time
                """, arguments: [audiobookID]).map { row in
                Block(id: row["id"], text: row["text"],
                      start: row["start"], end: row["end"])
            }
        }
        guard !blocks.isEmpty else { return }

        var records: [WordTimingRecord] = []
        for (i, block) in blocks.enumerated() {
            // End bound: next block's start, else this block's own end, else a
            // char-rate estimate (~15 cps) so the last block still gets ranges.
            let blockEnd: TimeInterval
            if i + 1 < blocks.count {
                blockEnd = max(block.start, blocks[i + 1].start)
            } else if let end = block.end, end > block.start {
                blockEnd = end
            } else {
                blockEnd = block.start + Double(block.text.count) / 15.0
            }

            let plain = block.text
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")

            for w in WordTimingInterpolator.interpolate(
                text: plain, blockStart: block.start, blockEnd: blockEnd) {
                records.append(WordTimingRecord(
                    audiobookID: audiobookID, epubBlockID: block.id,
                    wordIndex: w.index, word: w.word,
                    audioStartTime: w.start, audioEndTime: w.end,
                    confidence: 0.5, source: "interpolated"))
            }
        }
        try dao.insert(records)
    }
}
```

> The `plain`-text collapse here must match `ParagraphCardCell.configure` (newline-collapse, whitespace-trim, join with single space) so word indices line up with what the cell renders. Keep these two in sync.

- [ ] **Step 4: Run to verify pass**

Run: `make test-only FILTER=EchoTests/WordTimingMaterializerTests`
Expected: PASS (after matching the seed SQL column names).

- [ ] **Step 5: Call the materializer after every recalculation**

In `EchoCore/Services/AutoAlignmentService.swift`, locate the call to `recalculateTimeline()` (after anchors are inserted) and follow it with:

```swift
        try alignmentService.recalculateTimeline()
        try WordTimingMaterializer.materialize(audiobookID: audiobookID, writer: <writer>)
```

In `EchoCore/Services/AlignmentService.swift`, after the body of `recalculateTimeline(anchoredOnly:)` completes its timeline upsert, call the materializer for the same audiobook (use the `DatabaseWriter` the service already holds — see `AlignmentService` lines ~15-19 for the writer reference). Gate it so it only runs at the end of a successful recalculation, not per-block.

> **Read first:** open both services to get the exact writer property name and the exact line after which `recalculateTimeline` finishes. Do not invent a writer accessor — reuse the one the service already uses to build the timeline.

- [ ] **Step 6: Build both targets** (word timing code is in Shared + EchoCore; macOS reads `word_timing` in Phase B)

```bash
make build-tests
xcodebuild -project Echo.xcodeproj -scheme "Echo macOS" -destination 'platform=macOS' build 2>&1 | tail -5
```

Expected: tests green; macOS builds (it links `Shared/` but not EchoCore services — confirm `WordTimingMaterializer` is **not** referenced from macOS yet; only the record/DAO/interpolator in `Shared/` are).

- [ ] **Step 7: Parity review + commit**

Run the `cross-platform-parity-reviewer` agent (Shared/ changed). Then:

```bash
git add EchoCore/Services/WordTimingMaterializer.swift EchoCore/Services/AlignmentService.swift \
        EchoCore/Services/AutoAlignmentService.swift EchoTests/WordTimingMaterializerTests.swift
git commit -m "feat(align): materialize word_timing rows after each (re)alignment"
```

---

### Task A4: DTW per-word refinement (accuracy layer — deferrable)

> **Why separate:** A1–A3 already give working, monotonic word timings. This task overrides interpolated times with real WhisperKit audio times where a normalized DTW token maps cleanly to a rendered word. Karaoke works without it; it just makes word timing track the narrator's actual pace.

**Files:**
- Modify: `EchoCore/Services/TokenDTW.swift` (extract path helpers, add `wordMatches`)
- Create: `EchoCore/Services/WordTimingRefiner.swift` (pure)
- Modify: `EchoCore/Services/AutoAlignmentService.swift` (apply refiner)
- Test: `EchoTests/TokenDTWWordMatchTests.swift`, `EchoTests/WordTimingRefinerTests.swift`

- [ ] **Step 1: Write the failing TokenDTW word-match test**

```swift
// EchoTests/TokenDTWWordMatchTests.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Echo

struct TokenDTWWordMatchTests {
    @Test func emitsPerTokenMatchesWithAudioTimes() {
        let epub = [
            TokenDTW.EPubToken(text: "hello", blockID: "b0"),
            TokenDTW.EPubToken(text: "world", blockID: "b0"),
        ]
        let audio = [
            TokenDTW.AudioToken(text: "hello", time: 1.0),
            TokenDTW.AudioToken(text: "world", time: 1.6),
        ]
        let matches = TokenDTW.wordMatches(epub: epub, audio: audio)
        #expect(matches.count == 2)
        #expect(matches[0].blockID == "b0" && matches[0].wordIndexInBlock == 0)
        #expect(abs(matches[0].audioTime - 1.0) < 0.001)
        #expect(matches[1].wordIndexInBlock == 1)
        #expect(abs(matches[1].audioTime - 1.6) < 0.001)
        #expect(matches.allSatisfy { $0.runLength >= 1 })
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `make build-tests`
Expected: FAIL — `TokenDTW.wordMatches` / `WordMatch` undefined.

- [ ] **Step 3: Refactor TokenDTW to share the path, add `wordMatches`**

In `TokenDTW.swift`, extract the **forward DP + backtrack** (current lines 104–176), the **strong-run bookkeeping** (lines 178–203), and the **per-block token index** computation (lines 206–217) into file-private helpers, then have `alignCandidates` call them so its emitted candidates are **byte-for-byte unchanged** (the existing `TokenDTWTests` are the regression guard). Make `PathMatch` and `RunStats` file-scoped types.

```swift
// Add inside struct TokenDTW:

    struct WordMatch: Equatable {
        let blockID: String
        let wordIndexInBlock: Int
        let token: String
        let audioTime: TimeInterval
        let runLength: Int
    }

    /// Per-strong-token matches from the alignment path, for word-time refinement.
    /// Token granularity (normalized): callers map these onto rendered words.
    static func wordMatches(epub: [EPubToken], audio: [AudioToken]) -> [WordMatch] {
        guard !epub.isEmpty, !audio.isEmpty else { return [] }
        let matches = backtrackPath(epub: epub, audio: audio)
        let (runIDs, runs) = strongRuns(matches, audio: audio)
        let tokenIndexInBlock = tokenIndicesWithinBlocks(epub)
        var result: [WordMatch] = []
        for k in matches.indices where matches[k].strong {
            let m = matches[k]
            result.append(WordMatch(
                blockID: epub[m.epubIndex].blockID,
                wordIndexInBlock: tokenIndexInBlock[m.epubIndex],
                token: epub[m.epubIndex].text,
                audioTime: audio[m.audioIndex].time,
                runLength: runs[runIDs[k]].count))
        }
        return result
    }
```

Helper signatures to extract (move existing logic verbatim — do not retune costs):

```swift
    private struct PathMatch { let epubIndex: Int; let audioIndex: Int; let strong: Bool }
    private struct RunStats { var count: Int; var firstTime: TimeInterval; var lastTime: TimeInterval }

    private static func backtrackPath(epub: [EPubToken], audio: [AudioToken]) -> [PathMatch]
    private static func strongRuns(_ matches: [PathMatch], audio: [AudioToken]) -> (runIDs: [Int], runs: [RunStats])
    private static func tokenIndicesWithinBlocks(_ epub: [EPubToken]) -> [Int]
```

- [ ] **Step 4: Run to verify pass — including the existing DTW tests (no regression)**

Run: `make test-only FILTER=EchoTests/TokenDTWWordMatchTests`
Then: `make test-only FILTER=EchoTests/TokenDTWTests`
Expected: both PASS. If `TokenDTWTests` changed behavior, the refactor altered candidate emission — revert and re-extract more conservatively.

- [ ] **Step 5: Write the failing refiner test**

```swift
// EchoTests/WordTimingRefinerTests.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Echo

struct WordTimingRefinerTests {
    @Test func overridesMatchedWordsWithAudioTimesKeepsRestInterpolated() {
        let interpolated = [
            WordTimingInterpolator.Word(index: 0, word: "Hello", start: 0.0, end: 0.5),
            WordTimingInterpolator.Word(index: 1, word: "world", start: 0.5, end: 1.0),
        ]
        let matches = [
            TokenDTW.WordMatch(blockID: "b0", wordIndexInBlock: 1, token: "world",
                               audioTime: 0.9, runLength: 3),
        ]
        let refined = WordTimingRefiner.refine(
            words: interpolated, dtwMatches: matches, minRunLength: 3)
        // word 0 unchanged (interpolated), word 1 start pulled to the audio time
        #expect(abs(refined[0].start - 0.0) < 0.001 && refined[0].source == "interpolated")
        #expect(abs(refined[1].start - 0.9) < 0.001 && refined[1].source == "dtw")
        // still monotonic
        #expect(refined[1].start >= refined[0].start)
    }
}
```

- [ ] **Step 6: Implement `WordTimingRefiner`**

```swift
// EchoCore/Services/WordTimingRefiner.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Overrides interpolated word start times with DTW-derived audio times where a
/// normalized DTW token maps onto a rendered word. Pure and order-preserving.
///
/// DTW tokens are normalized (lowercased, numbers expanded, sub-2-char dropped),
/// so the mapping is greedy: walk the block's rendered words and the strong DTW
/// matches in parallel, and when `TokenDTW.normalize(renderedWord)` shares its
/// first token with the match's token, adopt the match's audio time.
enum WordTimingRefiner {
    struct RefinedWord: Equatable {
        let index: Int
        let word: String
        let start: TimeInterval
        let end: TimeInterval
        let source: String  // "interpolated" or "dtw"
    }

    static func refine(
        words: [WordTimingInterpolator.Word],
        dtwMatches: [TokenDTW.WordMatch],
        minRunLength: Int = 3
    ) -> [RefinedWord] {
        // Confident matches only, in block-word order.
        let strong = dtwMatches
            .filter { $0.runLength >= minRunLength }
            .sorted { $0.wordIndexInBlock < $1.wordIndexInBlock }

        var refined: [RefinedWord] = words.map {
            RefinedWord(index: $0.index, word: $0.word,
                        start: $0.start, end: $0.end, source: "interpolated")
        }

        var matchCursor = 0
        for i in refined.indices {
            guard matchCursor < strong.count else { break }
            guard let firstToken = TokenDTW.normalize(refined[i].word).first else { continue }
            if strong[matchCursor].token == firstToken {
                let start = strong[matchCursor].audioTime
                let end = max(start, refined[i].end)
                refined[i] = RefinedWord(index: refined[i].index, word: refined[i].word,
                                         start: start, end: end, source: "dtw")
                matchCursor += 1
            }
        }

        // Re-monotonize: a pulled-forward word must not precede its predecessor.
        for i in 1..<max(1, refined.count) {
            if refined[i].start < refined[i - 1].start {
                refined[i] = RefinedWord(index: refined[i].index, word: refined[i].word,
                                         start: refined[i - 1].start, end: max(refined[i - 1].start, refined[i].end),
                                         source: refined[i].source)
            }
        }
        return refined
    }
}
```

- [ ] **Step 7: Run to verify pass**

Run: `make test-only FILTER=EchoTests/WordTimingRefinerTests`
Expected: PASS.

- [ ] **Step 8: Apply the refiner in AutoAlignmentService**

In `AutoAlignmentService`, where DTW already builds `epubTokens` / `audioTokens` per chapter (~line 416 per exploration), capture `let dtwMatches = TokenDTW.wordMatches(epub: epubTokens, audio: audioTokens)` alongside the existing `alignCandidates`/`alignWithBisection` call, group matches by `blockID`, and have the post-recalculate word-materialization step refine each block's interpolated words before insert. Concretely: after `WordTimingMaterializer.materialize(...)`, run a refinement pass per block that has DTW matches, writing back `source: "dtw"` rows with `confidence: 0.85`.

> Keep this additive: if `wordMatches` returns nothing for a block (mistranscribed audio), the interpolated rows from A3 stand. The refiner never deletes words, only retimes matched ones.

- [ ] **Step 9: Build + commit**

```bash
make build-tests
git add EchoCore/Services/TokenDTW.swift EchoCore/Services/WordTimingRefiner.swift \
        EchoCore/Services/AutoAlignmentService.swift \
        EchoTests/TokenDTWWordMatchTests.swift EchoTests/WordTimingRefinerTests.swift
git commit -m "feat(align): refine word timings with DTW audio times where tokens match"
```

---

## Phase B: Karaoke Highlighting (iOS + macOS)

> **Prerequisite:** Phase A (word_timing rows exist). The data layer (resolver + cache load) is written once and shared; the rendering is implemented per platform.

### Task B1: `ReaderActiveBlockResolver.activeWord` (pure, shared)

**Files:**
- Modify: `Shared/ReaderActiveBlockResolver.swift`
- Test: `EchoTests/ReaderActiveWordTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// EchoTests/ReaderActiveWordTests.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Echo

struct ReaderActiveWordTests {
    private let rows: [ReaderActiveBlockResolver.WordRow] = [
        (start: 0.0, end: 1.0, blockID: "b0", wordIndex: 0),
        (start: 1.0, end: 2.0, blockID: "b0", wordIndex: 1),
        (start: 2.0, end: 3.0, blockID: "b1", wordIndex: 0),
    ]

    @Test func returnsWordWithinActiveBlock() {
        let w = ReaderActiveBlockResolver.activeWord(in: rows, time: 1.4, activeBlockID: "b0")
        #expect(w == 1)
    }

    @Test func ignoresWordsFromOtherBlocks() {
        // time 2.5 falls in b1's word, but active block is b0 → nil
        #expect(ReaderActiveBlockResolver.activeWord(in: rows, time: 2.5, activeBlockID: "b0") == nil)
    }

    @Test func nilWhenNoWordCoversTime() {
        #expect(ReaderActiveBlockResolver.activeWord(in: rows, time: 9.0, activeBlockID: "b1") == nil)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `make build-tests`
Expected: FAIL — `WordRow` / `activeWord` undefined.

- [ ] **Step 3: Add the word row type + resolver method**

```swift
// In ReaderActiveBlockResolver (Shared/ReaderActiveBlockResolver.swift):

    /// One word's audio `[start, end)` within a block, for karaoke highlighting.
    typealias WordRow = (
        start: TimeInterval, end: TimeInterval, blockID: String, wordIndex: Int
    )

    /// Resolves the active word index *within the already-resolved active block*.
    /// Block resolution is track-scoped upstream (`activeBlockID`), so word lookup
    /// only needs to scan the words of `activeBlockID`.
    /// - Returns: the word index whose `[start, end)` contains `time`, else `nil`.
    static func activeWord(
        in words: [WordRow],
        time: TimeInterval,
        activeBlockID: String?
    ) -> Int? {
        guard let activeBlockID else { return nil }
        for row in words where row.blockID == activeBlockID {
            if time >= row.start && time < row.end { return row.wordIndex }
        }
        return nil
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `make test-only FILTER=EchoTests/ReaderActiveWordTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Shared/ReaderActiveBlockResolver.swift EchoTests/ReaderActiveWordTests.swift
git commit -m "feat(reader): add pure activeWord resolution for karaoke"
```

---

### Task B2: Word cache + active-word publish in `ReaderFeedViewModel` (iOS)

**Files:**
- Modify: `EchoCore/ViewModels/ReaderFeedViewModel.swift`

- [ ] **Step 1: Add a word cache and active-word state**

Alongside the existing `timelineCache` (line ~23) and `activeBlockID` (line ~49):

```swift
    private var wordCache: [ReaderActiveBlockResolver.WordRow] = []
    /// (blockID, wordIndex) of the currently spoken word, for karaoke.
    private(set) var activeWord: (blockID: String, index: Int)?
```

- [ ] **Step 2: Load the word cache where the timeline cache is loaded**

In the same method that builds `timelineCache` from the DB (the `timeline_item`/`epub_block` query at lines ~236–246), also load word rows:

```swift
        let words = try WordTimingDAO(db: <writer>).words(forAudiobook: audiobookID)
        wordCache = words.map {
            (start: $0.audioStartTime, end: $0.audioEndTime,
             blockID: $0.epubBlockID, wordIndex: $0.wordIndex)
        }
```

> Use the same `DatabaseWriter` the view model already uses for the timeline query. If it executes raw SQL via a `DatabaseService`, instead run an equivalent `SELECT audio_start_time, audio_end_time, epub_block_id, word_index FROM word_timing WHERE audiobook_id = ? ORDER BY audio_start_time` and map to `WordRow` — match the file's existing query style.

- [ ] **Step 3: Compute the active word in `updateActiveBlock`**

In `updateActiveBlock(time:currentTrackChapterIndices:)` (lines ~354–366), after `activeBlockID` is resolved:

```swift
        let wordIdx = ReaderActiveBlockResolver.activeWord(
            in: wordCache, time: time, activeBlockID: foundBlockID)
        let newActiveWord = wordIdx.map { (blockID: foundBlockID ?? "", index: $0) }
        if newActiveWord?.blockID != activeWord?.blockID
            || newActiveWord?.index != activeWord?.index {
            activeWord = newActiveWord
        }
```

- [ ] **Step 4: Build**

Run: `make build-tests`
Expected: compiles (no test yet — behavior is exercised via B4 manual verification).

- [ ] **Step 5: Commit**

```bash
git add EchoCore/ViewModels/ReaderFeedViewModel.swift
git commit -m "feat(reader-ios): load word cache and publish active word"
```

---

### Task B3: Word highlighting in iOS cells

**Files:**
- Modify: `EchoCore/Views/Cells/ParagraphCardCell.swift`
- Modify: `EchoCore/Views/Cells/HeadingCardCell.swift`

- [ ] **Step 1: Store per-word `NSRange`s at configure time (ParagraphCardCell)**

Repeated words break naive substring search, so compute each rendered word's range **once** when the text is built. Add storage and extend `configure` to accept a highlighted index:

```swift
    private var wordRanges: [NSRange] = []
    private var baseAttributed: NSMutableAttributedString?
    private var highlightTint: UIColor = .systemBlue

    // Change the configure signature to add highlightedWordIndex (default nil
    // keeps every existing call site compiling):
    func configure(with block: EPubBlockRecord, font: UIFont, tint: UIColor,
                   lineSpacing: CGFloat, isExplicitHighlight: Bool,
                   searchQuery: String? = nil,
                   highlightedWordIndex: Int? = nil) {
```

Inside `configure`, after building `attributed` (line ~85) and the search-query loop, compute word ranges over `plainText` and store state, then apply the highlight:

```swift
        // Compute rendered-word ranges (whitespace split) for karaoke.
        wordRanges = Self.wordRanges(in: plainText)
        baseAttributed = attributed
        highlightTint = tint

        applyWordHighlight(highlightedWordIndex, baseFont: font)

        label.attributedText = label.attributedText ?? attributed
```

Add the helpers:

```swift
    static func wordRanges(in text: String) -> [NSRange] {
        var ranges: [NSRange] = []
        let ns = text as NSString
        var index = 0
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                               options: .byWords) { _, range, _, _ in
            ranges.append(range)
            index += 1
        }
        return ranges
    }

    /// Applies (or clears) the karaoke highlight without rebuilding base text.
    func applyWordHighlight(_ wordIndex: Int?, baseFont: UIFont) {
        guard let base = baseAttributed?.mutableCopy() as? NSMutableAttributedString else { return }
        if let wordIndex, wordIndex >= 0, wordIndex < wordRanges.count {
            let range = wordRanges[wordIndex]
            base.addAttribute(.backgroundColor,
                              value: highlightTint.withAlphaComponent(0.25), range: range)
            base.addAttribute(.font,
                              value: UIFont.systemFont(ofSize: baseFont.pointSize, weight: .semibold),
                              range: range)
        }
        label.attributedText = base
        lastHighlightFont = baseFont
    }

    private var lastHighlightFont: UIFont = .systemFont(ofSize: 16)
```

> **Index alignment:** `NSString.enumerateSubstrings(.byWords)` and `String.split(whereSeparator:)` (used by `WordTimingInterpolator`) must produce the same word count/order for the same `plainText`. Both split on whitespace and punctuation-adjacent words consistently for prose; verify with a quick manual check on a paragraph containing punctuation during B4. If they drift, switch the interpolator to the same `.byWords` enumeration so the two are defined identically.

- [ ] **Step 2: Mirror the pattern in HeadingCardCell**

`HeadingCardCell.configure` collapses to a single line and has a `highlightedText` helper. Add the same `wordRanges`/`baseAttributed`/`applyWordHighlight` members and a `highlightedWordIndex: Int? = nil` parameter; apply the highlight after the search-query branch.

- [ ] **Step 3: Build**

Run: `xcodebuild -project Echo.xcodeproj -scheme Echo -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`
Expected: compiles. Existing call sites still pass (new param defaulted).

- [ ] **Step 4: Commit**

```bash
git add EchoCore/Views/Cells/ParagraphCardCell.swift EchoCore/Views/Cells/HeadingCardCell.swift
git commit -m "feat(reader-ios): per-word highlight support in paragraph/heading cells"
```

---

### Task B4: Wire iOS karaoke data flow (throttled, no full reload)

**Files:**
- Modify: `EchoCore/Views/ReaderFeedCollectionView.swift`
- Modify: `EchoCore/Views/ReaderTab.swift`

- [ ] **Step 1: Pass the active word into the collection view**

Add a binding to `ReaderFeedCollectionView` (mirroring `@Binding var activeBlockID`):

```swift
    @Binding var activeWord: (blockID: String, index: Int)?
```

When configuring a `ParagraphCardCell`/`HeadingCardCell` in the coordinator's `cell(for:at:)`, pass the word index only for the active block:

```swift
        let wordIdx = (activeWord?.blockID == block.id) ? activeWord?.index : nil
        paraCell.configure(with: block, font: font, tint: tint, lineSpacing: lineSpacing,
                           isExplicitHighlight: isExplicitHighlight, searchQuery: searchQuery,
                           highlightedWordIndex: wordIdx)
```

- [ ] **Step 2: Update the active cell directly on word change (avoid reloadItems)**

In the coordinator, add a lightweight updater that retints the *visible* active cell without a diffable reload (reloads at word rate cause flicker):

```swift
    func updateActiveWord(_ word: (blockID: String, index: Int)?, in collectionView: UICollectionView) {
        guard let word,
              let indexPath = indexPathForBlock(word.blockID),  // reuse existing block→indexPath map
              let cell = collectionView.cellForItem(at: indexPath) else { return }
        if let para = cell as? ParagraphCardCell {
            para.applyWordHighlight(word.index, baseFont: currentBodyFont)
        } else if let heading = cell as? HeadingCardCell {
            heading.applyWordHighlight(word.index, baseFont: currentHeadingFont)
        }
    }
```

> Reuse the coordinator's existing block→IndexPath lookup (the same one `updateActiveBlock` uses, lines ~308–341). `currentBodyFont`/`currentHeadingFont` come from the coordinator's `settings`.

- [ ] **Step 3: Observe active word in `ReaderTab` with a throttle**

Next to the existing `.onChange(of: model.currentPlaybackTime)` (line ~218) that calls `updateActiveBlock`, the view model already updates `activeWord`. Bridge it to the collection view, throttled to ~12 Hz:

```swift
    .onChange(of: viewModel?.activeWord?.index) { _, _ in
        let now = CACurrentMediaTime()
        guard now - lastWordTick >= 0.08 else { return }   // ~12 Hz
        lastWordTick = now
        readerCoordinator?.updateActiveWord(viewModel?.activeWord, in: collectionView)
    }
```

Add `@State private var lastWordTick: TimeInterval = 0`. Wire `activeWord` from the view model into the `ReaderFeedCollectionView(activeWord:)` binding so newly-dequeued cells render the right word too.

- [ ] **Step 4: Build + verify on simulator**

Run: `xcodebuild -project Echo.xcodeproj -scheme Echo -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5`

Then verify visually with the simulator-tester agent or `/axiom:test-simulator`: import an aligned book, play, and confirm the highlighted word advances within the active paragraph and resets cleanly on block change. (Karaoke is inherently visual — capture a screenshot mid-playback.)

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Views/ReaderFeedCollectionView.swift EchoCore/Views/ReaderTab.swift
git commit -m "feat(reader-ios): wire throttled karaoke word highlighting end-to-end"
```

---

### Task B5: macOS karaoke (`MacReaderFeedView` / `MacBlockCardView`)

**Files:**
- Modify: `Echo macOS/Views/MacReaderFeedView.swift`

- [ ] **Step 1: Load the word cache in MacReaderFeedView**

Where the macOS reader builds its `timelineCache` (lines ~113–150), also load word rows via `WordTimingDAO` (it lives in `Shared/`, available to the macOS target):

```swift
    @State private var wordCache: [ReaderActiveBlockResolver.WordRow] = []
    @State private var activeWord: (blockID: String, index: Int)?

    // in the load function:
    let words = try WordTimingDAO(db: dbService.writer).words(forAudiobook: audiobookID)
    wordCache = words.map {
        (start: $0.audioStartTime, end: $0.audioEndTime,
         blockID: $0.epubBlockID, wordIndex: $0.wordIndex)
    }
```

- [ ] **Step 2: Resolve the active word at a higher cadence than the 0.5 s block poll**

The macOS reader polls `trackCurrentBlock` every 0.5 s — too coarse for words. In the same `while` loop, after resolving `currentBlockID`, resolve the word and shorten the sleep while playing:

```swift
    private func trackCurrentBlock() async {
        while !Task.isCancelled {
            if player.isPlaying, player.currentTime > 0 {
                currentBlockID = ReaderActiveBlockResolver.activeBlockID(
                    in: timelineCache, time: player.currentTime,
                    currentTrackChapterIndices: currentTrackChapterIndices)
                if let idx = ReaderActiveBlockResolver.activeWord(
                    in: wordCache, time: player.currentTime, activeBlockID: currentBlockID) {
                    activeWord = (blockID: currentBlockID ?? "", index: idx)
                } else {
                    activeWord = nil
                }
            } else {
                currentBlockID = nil
                activeWord = nil
            }
            // ~12 Hz while playing for smooth karaoke, 0.5 s when paused.
            try? await Task.sleep(nanoseconds: player.isPlaying ? 80_000_000 : 500_000_000)
        }
    }
```

- [ ] **Step 3: Render the word highlight in `MacBlockCardView`**

The card renders block text as plain `Text(...)`. Replace the paragraph/heading `Text` with an `AttributedString` that bolds + tints the active word when this card is the active block:

```swift
    private func highlightedText(_ text: String, activeWordIndex: Int?) -> AttributedString {
        var attributed = AttributedString(text)
        guard let activeWordIndex else { return attributed }
        let words = text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
        guard activeWordIndex >= 0, activeWordIndex < words.count else { return attributed }
        let target = words[activeWordIndex]
        // Find the n-th occurrence to handle repeats.
        var searchStart = attributed.startIndex
        var seen = 0
        while let r = attributed[searchStart...].range(of: String(target)) {
            if seen == indexOfWordOccurrence(words, activeWordIndex) {
                attributed[r].backgroundColor = .accentColor.opacity(0.25)
                attributed[r].font = .body.weight(.semibold)
                break
            }
            seen += 1
            searchStart = r.upperBound
        }
        return attributed
    }

    /// How many earlier words equal words[index] (to pick the right occurrence).
    private func indexOfWordOccurrence(_ words: [Substring], _ index: Int) -> Int {
        words[..<index].filter { $0 == words[index] }.count
    }
```

Pass `isActive ? activeWord.index : nil` into `highlightedText` from the card's parent (the `MacBlockCardView` that already receives `isActive`).

- [ ] **Step 4: Build macOS + verify**

Run: `xcodebuild -project Echo.xcodeproj -scheme "Echo macOS" -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: compiles. Launch the macOS app, play an aligned book, confirm the active word advances in the center reader.

- [ ] **Step 5: Parity review + commit**

Run `cross-platform-parity-reviewer` (both readers now consume word timings). Then:

```bash
git add "Echo macOS/Views/MacReaderFeedView.swift"
git commit -m "feat(reader-macos): word-by-word karaoke highlighting"
```

---

## Phase C: macOS Persistent Batch Queue (import → transcribe → align)

> **Prerequisite:** Phase A (so completed books get word timings too). macOS-only. Replaces the in-memory, align-only `MacBulkAlignmentService` flow with a DB-backed queue that survives app restart and runs the full per-book pipeline.

### Task C1: `batch_queue` schema, record, DAO

**Files:**
- Create: `Shared/Database/BatchQueueRecord.swift`
- Create: `Shared/Database/DAOs/BatchQueueDAO.swift`
- Create: `Shared/Database/Migrations/Schema_V20.swift`
- Modify: `Shared/Database/DatabaseService.swift` (register V20)
- Test: `EchoTests/BatchQueueDAOTests.swift`

- [ ] **Step 1: Write the failing DAO test**

```swift
// EchoTests/BatchQueueDAOTests.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Echo

struct BatchQueueDAOTests {
    @Test func enqueueAssignsIncreasingPositionsAndClaimNextIsFIFO() throws {
        let db = try DatabaseService(inMemory: ())
        let dao = BatchQueueDAO(db: db.writer)
        _ = try dao.enqueue(makeItem(name: "A"))
        _ = try dao.enqueue(makeItem(name: "B"))
        let first = try dao.nextQueued()
        #expect(first?.displayName == "A")
    }

    @Test func recoverInFlightResetsToQueued() throws {
        let db = try DatabaseService(inMemory: ())
        let dao = BatchQueueDAO(db: db.writer)
        let item = try dao.enqueue(makeItem(name: "A"))
        try dao.updateStatus(id: item.id!, status: .transcribing, progress: 0.4)
        try dao.recoverInFlight()  // simulate relaunch
        #expect(try dao.nextQueued()?.status == .queued)
    }

    private func makeItem(name: String) -> BatchQueueRecord {
        BatchQueueRecord(audiobookID: "bk-\(name)", sourceBookmark: Data(),
                         displayName: name, queuePosition: 0, status: .queued,
                         progress: 0, enqueuedAt: "2026-06-16T00:00:00Z")
    }
}
```

- [ ] **Step 2: Run to verify failure** — `make build-tests` → FAIL (types undefined).

- [ ] **Step 3: Create `BatchQueueRecord`**

```swift
// Shared/Database/BatchQueueRecord.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

enum BatchItemStatus: String, Codable {
    case queued, importing, transcribing, aligning, completed, failed
}

/// A persistent batch-processing queue entry. Survives app restart; `sourceBookmark`
/// is a macOS security-scoped bookmark so the file stays reachable after relaunch.
struct BatchQueueRecord: Identifiable, Equatable, Codable, FetchableRecord, MutablePersistableRecord {
    var id: Int64?
    var audiobookID: String
    var sourceBookmark: Data
    var displayName: String
    var queuePosition: Int
    var status: BatchItemStatus
    var progress: Double
    var statusMessage: String?
    var errorMessage: String?
    var enqueuedAt: String
    var startedAt: String?
    var completedAt: String?

    static let databaseTableName = "batch_queue"

    enum CodingKeys: String, CodingKey {
        case id
        case audiobookID = "audiobook_id"
        case sourceBookmark = "source_bookmark"
        case displayName = "display_name"
        case queuePosition = "queue_position"
        case status
        case progress
        case statusMessage = "status_message"
        case errorMessage = "error_message"
        case enqueuedAt = "enqueued_at"
        case startedAt = "started_at"
        case completedAt = "completed_at"
    }

    mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}
```

- [ ] **Step 4: Create `BatchQueueDAO`**

```swift
// Shared/Database/DAOs/BatchQueueDAO.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

struct BatchQueueDAO {
    let db: DatabaseWriter

    @discardableResult
    func enqueue(_ item: BatchQueueRecord) throws -> BatchQueueRecord {
        var copy = item
        try db.write { db in
            let maxPos = try Int.fetchOne(db, sql: "SELECT MAX(queue_position) FROM batch_queue") ?? -1
            copy.queuePosition = maxPos + 1
            try copy.insert(db)
        }
        return copy
    }

    func nextQueued() throws -> BatchQueueRecord? {
        try db.read { db in
            try BatchQueueRecord
                .filter(Column("status") == BatchItemStatus.queued.rawValue)
                .order(Column("queue_position"))
                .fetchOne(db)
        }
    }

    func allItems() throws -> [BatchQueueRecord] {
        try db.read { db in
            try BatchQueueRecord.order(Column("queue_position")).fetchAll(db)
        }
    }

    func updateStatus(id: Int64, status: BatchItemStatus, progress: Double? = nil,
                      message: String? = nil, error: String? = nil) throws {
        try db.write { db in
            guard var item = try BatchQueueRecord.fetchOne(db, key: id) else { return }
            item.status = status
            if let progress { item.progress = progress }
            if let message { item.statusMessage = message }
            if let error { item.errorMessage = error }
            if status == .completed || status == .failed {
                item.completedAt = ISO8601DateFormatter().string(from: Date())
            } else if item.startedAt == nil && status != .queued {
                item.startedAt = ISO8601DateFormatter().string(from: Date())
            }
            try item.update(db)
        }
    }

    /// On relaunch, any item left mid-flight (importing/transcribing/aligning)
    /// is reset to queued so the queue resumes cleanly.
    func recoverInFlight() throws {
        try db.write { db in
            let inFlight = [BatchItemStatus.importing, .transcribing, .aligning].map(\.rawValue)
            try db.execute(sql: """
                UPDATE batch_queue SET status = ?, progress = 0, started_at = NULL
                WHERE status IN (?, ?, ?)
                """, arguments: [BatchItemStatus.queued.rawValue] + inFlight)
        }
    }

    func deleteCompleted() throws {
        _ = try db.write { db in
            try BatchQueueRecord
                .filter(Column("status") == BatchItemStatus.completed.rawValue)
                .deleteAll(db)
        }
    }
}
```

- [ ] **Step 5: Create `Schema_V20`**

```swift
// Shared/Database/Migrations/Schema_V20.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

/// V20 — persistent macOS batch-processing queue.
enum Schema_V20 {
    nonisolated static func migrate(_ db: Database) throws {
        try db.create(table: "batch_queue") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("audiobook_id", .text).notNull()
            t.column("source_bookmark", .blob).notNull()
            t.column("display_name", .text).notNull()
            t.column("queue_position", .integer).notNull()
            t.column("status", .text).notNull().defaults(to: BatchItemStatus.queued.rawValue)
            t.column("progress", .double).notNull().defaults(to: 0.0)
            t.column("status_message", .text)
            t.column("error_message", .text)
            t.column("enqueued_at", .text).notNull()
            t.column("started_at", .text)
            t.column("completed_at", .text)
        }
    }
}
```

- [ ] **Step 6: Register V20** in `DatabaseService.runMigrations` after the V19 line:

```swift
        migrator.registerMigration("v19_word_timing") { db in try Schema_V19.migrate(db) }
        migrator.registerMigration("v20_batch_queue") { db in try Schema_V20.migrate(db) }  // ← add
        try migrator.migrate(writer)
```

- [ ] **Step 7: Run to verify pass** — `make test-only FILTER=EchoTests/BatchQueueDAOTests` → PASS.

- [ ] **Step 8: Schema review + commit**

Run `schema-migration-reviewer`, then:

```bash
git add Shared/Database/BatchQueueRecord.swift Shared/Database/DAOs/BatchQueueDAO.swift \
        Shared/Database/Migrations/Schema_V20.swift Shared/Database/DatabaseService.swift \
        EchoTests/BatchQueueDAOTests.swift
git commit -m "feat(db): add batch_queue table, record, and DAO (Schema V20)"
```

---

### Task C2: `MacBatchProcessingService` state machine (injected stages)

> Follows the project's DI rule (CLAUDE.md): concrete type + closure injection, unit-tested with fakes — no protocol-for-its-own-sake. The three pipeline stages are injected closures so the queue state machine is testable without WhisperKit/import side effects.

**Files:**
- Create: `Echo macOS/Services/MacBatchProcessingService.swift` (Task C3)
- Create (this task): `Shared/BatchQueueRunner.swift`
- Test: `EchoTests/BatchQueueRunnerTests.swift`

> **Test target note:** confirm `EchoTests` compiles macOS-only files. `MacBatchProcessingService` lives under `Echo macOS/`. If the test target cannot see it, make the state machine itself a small `Shared/` type (`BatchQueueRunner`) parameterized by injected async stage closures, and keep `MacBatchProcessingService` as the thin macOS `@Observable` wrapper that supplies real stages. Prefer this split — it keeps the testable core in `Shared/`.

- [ ] **Step 1: Write the failing state-machine test (fake stages)**

```swift
// EchoTests/BatchQueueRunnerTests.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing
@testable import Echo

@MainActor
struct BatchQueueRunnerTests {
    @Test func processesAllItemsFIFOAndMarksCompleted() async throws {
        let db = try DatabaseService(inMemory: ())
        let dao = BatchQueueDAO(db: db.writer)
        _ = try dao.enqueue(item("A")); _ = try dao.enqueue(item("B"))

        var processedOrder: [String] = []
        let runner = BatchQueueRunner(dao: dao, stages: .init(
            run: { rec, _ in processedOrder.append(rec.displayName) }))
        await runner.drain()

        #expect(processedOrder == ["A", "B"])
        #expect(try dao.allItems().allSatisfy { $0.status == .completed })
    }

    @Test func failingStageMarksItemFailedAndContinues() async throws {
        let db = try DatabaseService(inMemory: ())
        let dao = BatchQueueDAO(db: db.writer)
        _ = try dao.enqueue(item("A")); _ = try dao.enqueue(item("B"))
        let runner = BatchQueueRunner(dao: dao, stages: .init(
            run: { rec, _ in if rec.displayName == "A" { throw TestError.boom } }))
        await runner.drain()
        let items = try dao.allItems()
        #expect(items.first(where: { $0.displayName == "A" })?.status == .failed)
        #expect(items.first(where: { $0.displayName == "B" })?.status == .completed)
    }

    enum TestError: Error { case boom }
    private func item(_ n: String) -> BatchQueueRecord {
        BatchQueueRecord(audiobookID: "bk-\(n)", sourceBookmark: Data(), displayName: n,
                         queuePosition: 0, status: .queued, progress: 0,
                         enqueuedAt: "2026-06-16T00:00:00Z")
    }
}
```

- [ ] **Step 2: Run to verify failure** — `make build-tests` → FAIL.

- [ ] **Step 3: Implement `BatchQueueRunner` (Shared) + stage struct**

```swift
// Shared/BatchQueueRunner.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Testable sequential queue engine. Drains `batch_queue` one item at a time,
/// driving the injected `run` closure per item and recording status transitions.
/// The macOS wrapper supplies a real `run` (import → transcribe → align → word
/// timings); tests supply a fake.
@MainActor
final class BatchQueueRunner {
    struct Stages {
        /// Processes one item end-to-end. Throwing marks the item failed.
        /// The `progress` callback (0–1) is forwarded to the DAO.
        let run: (BatchQueueRecord, _ progress: @MainActor (BatchItemStatus, Double, String?) -> Void) async throws -> Void
    }

    private let dao: BatchQueueDAO
    private let stages: Stages
    private(set) var isRunning = false

    init(dao: BatchQueueDAO, stages: Stages) {
        self.dao = dao
        self.stages = stages
    }

    /// Processes queued items until none remain.
    func drain() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        while let item = try? dao.nextQueued(), let id = item.id {
            do {
                try stages.run(item) { [dao] status, progress, message in
                    try? dao.updateStatus(id: id, status: status, progress: progress, message: message)
                }
                try? dao.updateStatus(id: id, status: .completed, progress: 1.0)
            } catch {
                try? dao.updateStatus(id: id, status: .failed, error: error.localizedDescription)
            }
        }
    }
}
```

- [ ] **Step 4: Run to verify pass** — `make test-only FILTER=EchoTests/BatchQueueRunnerTests` → PASS.

- [ ] **Step 5: Commit**

```bash
git add Shared/BatchQueueRunner.swift EchoTests/BatchQueueRunnerTests.swift
git commit -m "feat(batch): add testable sequential BatchQueueRunner"
```

---

### Task C3: Real pipeline stages + folder enqueue

**Files:**
- Create: `Echo macOS/Services/MacBatchProcessingService.swift`
- Modify: `Echo macOS/Services/MacBulkAlignmentService.swift` (reuse scan → enqueue)

- [ ] **Step 1: Create the macOS `@Observable` wrapper supplying real stages**

```swift
// Echo macOS/Services/MacBatchProcessingService.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Observation

/// macOS batch queue: DB-backed, survives restart, runs import → transcribe →
/// align → word timings per book. Wraps the shared `BatchQueueRunner` with real
/// stages and exposes queue state for `MacBatchQueueView`.
@MainActor
@Observable
final class MacBatchProcessingService {
    private let dbService: DatabaseService
    private let dao: BatchQueueDAO
    private let alignmentService = MacAlignmentService()

    private(set) var items: [BatchQueueRecord] = []
    private(set) var isProcessing = false
    private var runner: BatchQueueRunner?

    init(dbService: DatabaseService) {
        self.dbService = dbService
        self.dao = BatchQueueDAO(db: dbService.writer)
    }

    /// Call once at launch: reset interrupted items, then resume.
    func resumeOnLaunch() {
        try? dao.recoverInFlight()
        refresh()
        start()
    }

    func enqueue(fileURL: URL) throws {
        let bookmark = try fileURL.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        let id = "batch-\(UUID().uuidString)"
        _ = try dao.enqueue(BatchQueueRecord(
            audiobookID: id, sourceBookmark: bookmark,
            displayName: fileURL.deletingPathExtension().lastPathComponent,
            queuePosition: 0, status: .queued, progress: 0,
            enqueuedAt: ISO8601DateFormatter().string(from: Date())))
        refresh()
        start()
    }

    func start() {
        guard runner == nil else { return }
        let runner = BatchQueueRunner(dao: dao, stages: makeStages())
        self.runner = runner
        Task { [weak self] in
            self?.isProcessing = true
            await runner.drain()
            self?.isProcessing = false
            self?.runner = nil
            self?.refresh()
        }
    }

    func refresh() { items = (try? dao.allItems()) ?? [] }
    func clearCompleted() { try? dao.deleteCompleted(); refresh() }

    private func makeStages() -> BatchQueueRunner.Stages {
        let dbService = self.dbService
        let alignmentService = self.alignmentService
        return .init(run: { [weak self] record, progress in
            // Resolve the security-scoped bookmark for restart-safe file access.
            var stale = false
            let url = try URL(resolvingBookmarkData: record.sourceBookmark,
                              options: .withSecurityScope, relativeTo: nil,
                              bookmarkDataIsStale: &stale)
            guard url.startAccessingSecurityScopedResource() else {
                throw NSError(domain: "Batch", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "Cannot access file"])
            }
            defer { url.stopAccessingSecurityScopedResource() }

            // 1) Import (EPUB companion + audio) — reuse the existing import path.
            progress(.importing, 0.05, "Importing…")
            try await self?.importBook(at: url, dbService: dbService)

            // 2) Transcribe (macOS CLI TranscriptionManager path).
            progress(.transcribing, 0.33, "Transcribing…")
            try await self?.transcribeBook(at: url)

            // 3) Align (shared TokenDTW) + 4) word timings (Phase A).
            progress(.aligning, 0.66, "Aligning…")
            try await alignmentService.align(/* audio + epub for this book */)
            // recalculate + materialize word timings happens inside the align path
            // (it calls AlignmentService.recalculateTimeline → WordTimingMaterializer).
            self?.refresh()
        })
    }

    // importBook / transcribeBook: thin adapters around EPUBImportCoordinator and
    // the macOS TranscriptionManager. Implement against their real signatures
    // (read those files first). Keep them here so the stage closure stays small.
    private func importBook(at url: URL, dbService: DatabaseService) async throws { /* … */ }
    private func transcribeBook(at url: URL) async throws { /* … */ }
}
```

> **Read before implementing `importBook`/`transcribeBook`:** open `EPUBImportCoordinator` (signature `importEPUB(from:to:databaseService:chapters:duration:)`), the macOS `TranscriptionManager` (process-based CLI), and `MacAlignmentService.align(...)` to wire exact arguments. These two adapters are the only non-mechanical glue; everything else is covered by C2's tests. Verify `MacAlignmentService.align` ends by calling `AlignmentService.recalculateTimeline` so `WordTimingMaterializer` runs — if it does not, add the materializer call there (gated to macOS via the shared writer).

- [ ] **Step 2: Reuse the bulk folder scan to enqueue**

In `MacBulkAlignmentService.swift`, keep the recursive audio-file scan + EPUB/PDF companion matching, but add a method that enqueues each discovered book into the new service instead of aligning inline:

```swift
    /// Scans `folderURL` and enqueues every audio file with a companion into the
    /// persistent batch queue. Reuses the existing recursive scan logic.
    func enqueueFolder(_ folderURL: URL, into service: MacBatchProcessingService) throws {
        for audioURL in discoverAudioFiles(in: folderURL) {  // existing private scan
            try service.enqueue(fileURL: audioURL)
        }
    }
```

- [ ] **Step 3: Build macOS**

Run: `xcodebuild -project Echo.xcodeproj -scheme "Echo macOS" -destination 'platform=macOS' build 2>&1 | tail -20`
Expected: compiles after the two adapters are filled in.

- [ ] **Step 4: Commit**

```bash
git add "Echo macOS/Services/MacBatchProcessingService.swift" "Echo macOS/Services/MacBulkAlignmentService.swift"
git commit -m "feat(batch-macos): persistent full-pipeline batch service with folder enqueue"
```

---

### Task C4: Batch queue UI + app wiring + restart recovery

**Files:**
- Create: `Echo macOS/Views/MacBatchQueueView.swift`
- Modify: `Echo macOS/Echo_macOSApp.swift`

- [ ] **Step 1: Create `MacBatchQueueView`**

```swift
// Echo macOS/Views/MacBatchQueueView.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct MacBatchQueueView: View {
    @Environment(MacBatchProcessingService.self) private var service

    var body: some View {
        VStack(spacing: 0) {
            if service.items.isEmpty {
                ContentUnavailableView("No Books Queued", systemImage: "square.stack.3d.up",
                    description: Text("Add a folder to process books overnight."))
            } else {
                List(service.items) { item in MacBatchQueueRow(item: item) }
            }
        }
        .toolbar {
            ToolbarItem {
                Button("Clear Completed") { service.clearCompleted() }
                    .disabled(!service.items.contains { $0.status == .completed })
            }
        }
        .frame(minWidth: 380, minHeight: 320)
        .onAppear { service.refresh() }
    }
}

private struct MacBatchQueueRow: View {
    let item: BatchQueueRecord
    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayName).font(.headline)
                if let msg = item.statusMessage ?? item.errorMessage {
                    Text(msg).font(.caption).foregroundStyle(.secondary)
                }
                if item.status != .queued && item.status != .completed && item.status != .failed {
                    ProgressView(value: item.progress)
                }
            }
        }.padding(.vertical, 4)
    }
    private var icon: some View {
        Group {
            switch item.status {
            case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
            case .importing: Image(systemName: "square.and.arrow.down").foregroundStyle(.blue)
            case .transcribing: Image(systemName: "waveform").foregroundStyle(.blue)
            case .aligning: Image(systemName: "text.alignleft").foregroundStyle(.orange)
            case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            }
        }.frame(width: 24)
    }
}
```

- [ ] **Step 2: Wire the service, menu, and restart recovery in `Echo_macOSApp.swift`**

```swift
    @State private var batchService: MacBatchProcessingService

    init() {
        // … existing db init …
        self.batchService = MacBatchProcessingService(dbService: db)
    }

    // In the WindowGroup content, inject + resume on launch:
    MacTriPaneView()
        .environment(batchService)
        .task { batchService.resumeOnLaunch() }

    // Add a sheet/window state and menu commands (replace the inline-align command):
    CommandMenu("Batch") {
        Button("Open Batch Queue") { showBatchQueue = true }
            .keyboardShortcut("b", modifiers: [.command, .shift])
        Button("Add Folder to Queue…") {
            if let folder = chooseFolder() {  // existing NSOpenPanel helper
                try? bulkAlignmentService.enqueueFolder(folder, into: batchService)
            }
        }
    }
```

Add a sheet for `MacBatchQueueView()` bound to `showBatchQueue`, injecting `batchService` into its environment.

> Keep the existing single-book open flow (`showOpenPanel`) untouched — batch is additive. The old "Bulk Align Folder…" (`⌘⌥B`) command is superseded by "Add Folder to Queue…"; remove the old command and its `MacBulkAlignmentProgressView` sheet only after the queue UI is verified working.

- [ ] **Step 3: Build macOS + manual verification**

Run: `xcodebuild -project Echo.xcodeproj -scheme "Echo macOS" -destination 'platform=macOS' build 2>&1 | tail -5`

Manually: add a folder, confirm items appear and advance through importing/transcribing/aligning/completed; quit mid-run and relaunch → an interrupted item resets to queued and processing resumes.

- [ ] **Step 4: Commit**

```bash
git add "Echo macOS/Views/MacBatchQueueView.swift" "Echo macOS/Echo_macOSApp.swift"
git commit -m "feat(batch-macos): batch queue UI, menu, and restart recovery"
```

---

## Phase D: M4B Chapter Markers via `swift-audio-marker`

> **Prerequisite:** none (independent). iOS-only (narration is `#if os(iOS)`; macOS excludes the Narration folder). The export pipeline already builds the audio and collects `ChapterAtom`s — only the marker write is stubbed.

### Task D1: Add the `swift-audio-marker` SPM dependency

**Files:**
- Modify: `Echo.xcodeproj/project.pbxproj`

- [ ] **Step 1: Add the package in Xcode**

In Xcode: File ▸ Add Package Dependencies… → `https://github.com/atelier-socle/swift-audio-marker.git`, rule **Up to Next Major** from `0.1.0`. Add the **`AudioMarker`** product to the **Echo (iOS)** target only (not macOS, not widget/watch).

> CLI alternative if not using the IDE: add an `XCRemoteSwiftPackageReference` + `XCSwiftPackageProductDependency` for `AudioMarker` to the Echo target in `project.pbxproj`, matching the existing WhisperKit/FluidAudio/GRDB entries. Run `xcodebuild -resolvePackageDependencies` afterward.

- [ ] **Step 2: Verify resolution**

Run: `xcodebuild -project Echo.xcodeproj -scheme Echo -destination 'platform=iOS Simulator,name=iPhone 16' -resolvePackageDependencies 2>&1 | tail -5`
Expected: `swift-audio-marker` resolves; no errors.

- [ ] **Step 3: Commit**

```bash
git add Echo.xcodeproj/project.pbxproj Echo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
git commit -m "build(ios): add swift-audio-marker SPM dependency"
```

---

### Task D2: Replace the AudioMarker stub with the real engine

> **Name collisions to resolve:** the package's **module** is `AudioMarker`, and it exports a `Chapter`/`ChapterList`. Echo already has a local `struct AudioMarker` (the stub) **and** a `Chapter` model (`Models/Chapter.swift`). So: rename the local writer type to `ChapterMarkerWriter`, and fully-qualify the package types as `AudioMarker.Chapter` / `AudioMarker.ChapterList`.

**Files:**
- Modify: `EchoCore/Services/Narration/AudioMarkerStub.swift`
- Modify: `EchoCore/Services/Narration/NarrationExportService.swift`

- [ ] **Step 1: Rewrite the writer to call the package**

```swift
// EchoCore/Services/Narration/AudioMarkerStub.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
#if os(iOS)
import AudioMarker
#endif

/// One chapter boundary for the exported m4b.
struct ChapterAtom {
    let startTime: Double
    let title: String
}

/// Writes real Nero (`chpl`) + QuickTime (`chap`) chapter atoms via the
/// `swift-audio-marker` package. Replaces the former copy-only stub.
struct ChapterMarkerWriter {
    enum WriteError: Error { case unavailableOnPlatform }

    /// Copies `sourceURL` → `outputURL`, then writes chapter atoms in place.
    func writeChapters(_ chapters: [ChapterAtom], to sourceURL: URL, outputURL: URL) async throws {
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }
        try FileManager.default.copyItem(at: sourceURL, to: outputURL)
        #if os(iOS)
        let engine = AudioMarkerEngine()
        let list = AudioMarker.ChapterList(chapters.map { atom in
            AudioMarker.Chapter(start: .seconds(atom.startTime), title: atom.title)
        })
        try await engine.writeChapters(list, to: outputURL)
        #else
        throw WriteError.unavailableOnPlatform
        #endif
    }
}
```

> **Confirm the time type at build time:** the README shows `Chapter(start: .seconds(30), title:)` and `.zero`. If `.seconds` is on a custom type rather than `Duration`, the compiler will say so — adjust to the package's exact start-time type (e.g. `CMTime`/`Duration`/a package `AudioTime`). This is the one spot to verify against Xcode quick-help after the package resolves.

- [ ] **Step 2: Update the call site + use real chapter titles**

In `NarrationExportService.exportM4B`, replace the chapter naming and the marker call:

```swift
            // Use the rendered track's real title instead of "Chapter N".
            let chapterName = trackTitles[index] ?? "Chapter \(index + 1)"
            chapters.append(ChapterAtom(startTime: currentPosition.seconds, title: chapterName))
```

```swift
        // Inject chapters to make it an M4B
        let writer = ChapterMarkerWriter()
        do {
            try await writer.writeChapters(chapters, to: tempM4A, outputURL: outputURL)
            try? FileManager.default.removeItem(at: tempM4A)
        } catch {
            throw ExportError.chapterAtomWriteFailed
        }
```

Load `trackTitles` from `TrackRecord` for the book (via `TrackDAO`, ordered by `sortOrder`) at the top of `exportM4B`, mapping `index → title`. `TrackRecord` has `title` and `sortOrder` (no `cumulativeStartTime`; the export already accumulates position itself).

> The method is already `async` inside an `actor`; `await writer.writeChapters` is fine. Update the type doc comment on the service to drop the "1.0 does not embed markers" caveat.

- [ ] **Step 3: Build iOS**

Run: `xcodebuild -project Echo.xcodeproj -scheme Echo -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -10`
Expected: compiles (after confirming the package start-time type and `TrackDAO` title lookup).

- [ ] **Step 4: Commit**

```bash
git add EchoCore/Services/Narration/AudioMarkerStub.swift EchoCore/Services/Narration/NarrationExportService.swift
git commit -m "feat(export): write real m4b chapter markers via swift-audio-marker"
```

---

### Task D3: Round-trip verification test

**Files:**
- Test: `EchoTests/ChapterMarkerWriterTests.swift`

- [ ] **Step 1: Write a write→read round-trip test**

```swift
// EchoTests/ChapterMarkerWriterTests.swift
// SPDX-License-Identifier: GPL-3.0-or-later
#if os(iOS)
import AVFoundation
import Foundation
import Testing
import AudioMarker
@testable import Echo

struct ChapterMarkerWriterTests {
    /// Writes two chapters into a generated silent m4a and reads them back via
    /// AVFoundation's chapter metadata groups.
    @Test func writesChaptersReadableByAVFoundation() async throws {
        let source = try makeSilentM4A(seconds: 6)
        defer { try? FileManager.default.removeItem(at: source) }
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("m4b")
        defer { try? FileManager.default.removeItem(at: output) }

        try await ChapterMarkerWriter().writeChapters(
            [ChapterAtom(startTime: 0, title: "Intro"),
             ChapterAtom(startTime: 3, title: "Body")],
            to: source, outputURL: output)

        let asset = AVURLAsset(url: output)
        let locales = try await asset.load(.availableChapterLocales)
        let groups = try await asset.loadChapterMetadataGroups(
            bestMatchingPreferredLanguages: locales.map(\.identifier))
        #expect(groups.count == 2)
    }

    // makeSilentM4A: render N seconds of silence to a temp .m4a via AVAssetWriter.
    private func makeSilentM4A(seconds: Double) throws -> URL { /* standard AVAssetWriter silence */ }
}
#endif
```

> If generating silent audio in-test is heavy/flaky, mark this `@Test(.disabled("manual: requires audio fixture"))` and instead verify once manually by exporting a real narrated book and opening the m4b in Books.app / a chapter-aware player. Do not leave a fake green test — either it really round-trips or it's explicitly manual.

- [ ] **Step 2: Run / or mark manual**

Run: `make test-only FILTER=EchoTests/ChapterMarkerWriterTests`
Expected: PASS, or explicitly skipped with a manual-verification note.

- [ ] **Step 3: Commit**

```bash
git add EchoTests/ChapterMarkerWriterTests.swift
git commit -m "test(export): round-trip chapter markers through AVFoundation"
```

---

### Task D4: iOS export entry point

**Files:**
- Create (if missing): `EchoCore/Views/ExportProgressView.swift`
- Modify (if needed): `EchoCore/Views/NowPlayingTab.swift`

- [ ] **Step 1: Check whether an export entry point already exists**

Run: `grep -rn "exportM4B\|ExportProgressView\|exportChapterFiles" EchoCore/Views EchoCore/ViewModels`
If a UI path already calls `exportM4B`, only verify it surfaces markers now (skip to Step 4). Otherwise add the view below.

- [ ] **Step 2: Create `ExportProgressView`**

```swift
// EchoCore/Views/ExportProgressView.swift
// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct ExportProgressView: View {
    let audiobookID: String
    let bookTitle: String
    @State private var isExporting = true
    @State private var exportedURL: URL?
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 20) {
            if isExporting {
                ProgressView("Exporting M4B with chapters…")
            } else if let url = exportedURL {
                Label("Export complete", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                ShareLink(item: url)
            } else if let errorText {
                Label(errorText, systemImage: "xmark.circle.fill").foregroundStyle(.red)
            }
        }
        .padding()
        .task { await runExport() }
    }

    private func runExport() async {
        let service = NarrationExportService()
        let cache = /* narration cache dir for this book */ FileManager.default.temporaryDirectory
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(bookTitle).m4b")
        do {
            try await service.exportM4B(for: audiobookID, bookTitle: bookTitle,
                                        cacheDirectory: cache, outputURL: output)
            exportedURL = output
        } catch {
            errorText = error.localizedDescription
        }
        isExporting = false
    }
}
```

> Resolve the real narration cache directory the same way `NarrationService`/`NarrationExportService` callers do (read those for the exact path helper). Do not hardcode `temporaryDirectory` if a dedicated cache dir exists.

- [ ] **Step 3: Add an entry point in the narration UI**

In `NowPlayingTab` (or wherever narration completion is shown), add an "Export as M4B" button gated on narration being rendered, presenting `ExportProgressView` in a sheet. Keep it `#if os(iOS)` consistent with the rest of narration.

- [ ] **Step 4: Build + commit**

```bash
xcodebuild -project Echo.xcodeproj -scheme Echo -destination 'platform=iOS Simulator,name=iPhone 16' build 2>&1 | tail -5
git add EchoCore/Views/ExportProgressView.swift EchoCore/Views/NowPlayingTab.swift
git commit -m "feat(export): iOS M4B export entry point with share sheet"
```

---

## Cross-Cutting: Documentation (do not skip)

CLAUDE.md mandates doc sync whenever a feature or the architecture changes. After each phase merges, update the living docs (use the `doc-sync` skill):

- [ ] **ARCHITECTURE.md** — document: the `word_timing` table + interpolation/DTW-refine pipeline (Phase A); karaoke data flow through `ReaderActiveBlockResolver.activeWord` on both readers (Phase B); the persistent `batch_queue` + `BatchQueueRunner` (Phase C); real chapter-marker export via `swift-audio-marker` (Phase D).
- [ ] **README.md** — mention karaoke read-along, macOS overnight batch queue, and m4b chapter export under features.
- [ ] **CHANGELOG.md** — one entry per phase, Conventional-Commits style.
- [ ] **Schema docs** — note V19/V20 are additive (no EPUB re-import or re-alignment forced by the migration itself; karaoke does require running alignment once to populate `word_timing`).

```bash
git add ARCHITECTURE.md README.md CHANGELOG.md
git commit -m "docs: word timings, karaoke, macOS batch queue, m4b chapter export"
```

---

## Dependency Graph

```
Phase A (word timings) ── independent
├── A1 word_timing schema/record/DAO
├── A2 WordTimingInterpolator (pure)        ── needs nothing
├── A3 WordTimingMaterializer + wiring      ── needs A1, A2
└── A4 DTW refinement (deferrable)          ── needs A1, A3

Phase B (karaoke) ── needs A1–A3 (word rows must exist)
├── B1 resolver.activeWord (pure)
├── B2 iOS view model word cache            ── needs B1
├── B3 iOS cell highlighting
├── B4 iOS wiring (throttled)               ── needs B2, B3
└── B5 macOS reader highlighting            ── needs B1

Phase C (macOS batch) ── independent of A/B (but completed books get word timings via A3)
├── C1 batch_queue schema/record/DAO
├── C2 BatchQueueRunner (pure-ish, tested)  ── needs C1
├── C3 real stages + folder enqueue         ── needs C2
└── C4 UI + app wiring + recovery           ── needs C3

Phase D (m4b markers) ── fully independent
├── D1 add SPM dep
├── D2 real ChapterMarkerWriter             ── needs D1
├── D3 round-trip test                      ── needs D2
└── D4 iOS export UI                         ── needs D2
```

## Testing Strategy

| Task | Suite (Swift Testing) | Covers |
|------|----------------------|--------|
| A1 | `WordTimingDAOTests` | Insert/fetch/order/delete-scoping |
| A2 | `WordTimingInterpolatorTests` | Proportional split, monotonicity, empty text |
| A3 | `WordTimingMaterializerTests` | Block→word materialization, re-run clears |
| A4 | `TokenDTWWordMatchTests`, `WordTimingRefinerTests`, **`TokenDTWTests` (regression)** | Path extraction, token→word override, **no candidate regression** |
| B1 | `ReaderActiveWordTests` | Word lookup scoped to active block |
| B2–B5 | Manual (simulator + macOS app) | Visual word advance, reset on block change |
| C1 | `BatchQueueDAOTests` | Enqueue/FIFO/recover-in-flight |
| C2 | `BatchQueueRunnerTests` | Sequential drain, failure isolation |
| C3–C4 | Manual (macOS) | Full pipeline, restart recovery |
| D2–D3 | `ChapterMarkerWriterTests` (or manual) | Markers readable by AVFoundation |

**Commands:** `make build-tests` once, then `make test-only FILTER=EchoTests/<Suite>` per suite; `make test` for the full run. macOS: `xcodebuild -project Echo.xcodeproj -scheme "Echo macOS" -destination 'platform=macOS' build` (single invocation — never run two `xcodebuild`s concurrently on this 16 GB machine, never enable parallel testing).

## Risk Register

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| Rendered-word index (cells/interpolator) drifts from DTW token index | Medium | Foundation is interpolation at rendered-word granularity; DTW refine maps by re-normalizing each rendered word. Define `WordTimingInterpolator` split == cell `.byWords` enumeration; verify in B4. |
| Refactoring `TokenDTW` regresses tuned anchor emission | Medium | Extract only the mechanical DP/backtrack/run helpers; `alignCandidates` output unchanged; **`TokenDTWTests` is the gate** (Task A4 Step 4). |
| Word-rate cell reloads cause flicker | Low | Update the active cell directly (`applyWordHighlight`), never `reloadItems`; throttle to ~12 Hz. |
| macOS 0.5 s poll too coarse for karaoke | — | Shorten the poll to ~80 ms while playing (B5). |
| Batch test target can't see macOS-only service | Medium | Testable core (`BatchQueueRunner`) lives in `Shared/`; macOS wrapper supplies real stages (C2 note). |
| Security-scoped file lost after restart | Medium | Persist `bookmarkData(.withSecurityScope)`; resolve + `startAccessingSecurityScopedResource` per item (C3). |
| `swift-audio-marker` start-time type differs from README | Low | Single verification point in D2; compiler-guided fix. Package is pure-Swift, zero-dep, supports Nero+QuickTime atoms. |
| `AudioMarker` module name clashes with local type / `Chapter` model | High (compile) | Rename local type → `ChapterMarkerWriter`; fully-qualify `AudioMarker.Chapter`/`AudioMarker.ChapterList` (D2). |
| word_timing bloats DB for huge books | Low | One row per rendered word; cleared+rebuilt per alignment; indexed by (book, block). Add a settings toggle later if needed (YAGNI now). |

## Deferred / Out of Scope

- **macOS player convergence** (single shared PlayerModel) — explicitly dropped; standalone future refactor with its own device audio verification.
- **Embedding alignment metadata in the m4b** (round-trip) — `swift-audio-marker` supports synchronized/karaoke lyrics formats (WebVTT/SRT), a natural future home for word timings, but not required for chapter markers.
- **iOS batch queue** — overnight processing is a desktop use case; iOS background limits make it unreliable.
- **Sentence granularity** (`GranularityLevel.sentence`) — karaoke targets words; sentence-level not needed.

---

## Self-Review

- **Spec coverage:** macOS parity (resolved: drop convergence, keep native — §"What changed"); word-level alignment (Phase A); karaoke iOS+macOS (Phase B, both readers); batch macOS persistent full pipeline (Phase C); m4b via swift-audio-marker (Phase D). All four user decisions implemented.
- **Type consistency:** `WordTimingRecord`/`WordTimingDAO`/`word_timing`; `WordTimingInterpolator.Word`; `WordTimingMaterializer.materialize`; `ReaderActiveBlockResolver.WordRow`/`activeWord`; `BatchQueueRecord`/`BatchQueueDAO`/`BatchItemStatus`/`BatchQueueRunner`; `ChapterMarkerWriter`/`ChapterAtom`/`AudioMarker.ChapterList` — names used consistently across tasks.
- **Conventions verified against real files:** DAO `let db: DatabaseWriter` (AlignmentAnchorDAO); migration bare-enum `nonisolated static func migrate` + manual `registerMigration` (Schema_V18/DatabaseService:88–111); `DatabaseService(inMemory: ())` for tests; `MutablePersistableRecord` + snake_case `CodingKeys`; cell `NSMutableAttributedString` + `NSRange(range, in:)` (ParagraphCardCell); export `ChapterAtom`/`writeChapters` call site (NarrationExportService:96–98); package API from its README.
- **Known verify-before-coding points (not placeholders):** exact `epub_block`/`timeline_item` column names (A3 seed SQL); the writer accessor on each alignment service (A3 Step 5); `EPUBImportCoordinator`/`TranscriptionManager`/`MacAlignmentService` signatures (C3 adapters); the package start-time type and `TrackDAO` title lookup (D2); narration cache dir (D4). Each is flagged inline with a "read first" note.
