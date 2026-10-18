# Narration Phase 2: segment streaming — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut narration time-to-first-audio from ~73 s to ~5 s by rendering each chapter as ordered **segment** files (small first segment), starting playback after segment 1.

**Architecture:** A new pure `NarrationSegmentPlanner` splits each `PlannedChapter` into adaptively-sized `PlannedSegment`s. The renderer renders one segment → one file → one `Track`, anchors 0-based per segment. Read-along scope drops from chapter→segment via a new `timeline_item.segment_key` column (Schema V24) carried into the shared `ReaderActiveBlockResolver`. Outline/playlist stay chapter-level; resume/export map segments back to their chapter.

**Tech Stack:** Swift, GRDB (migration), Swift Testing, AVFoundation (unchanged engine).

**Design spec:** `docs/superpowers/specs/2026-06-21-narration-streaming-and-onnx-tuning-design.md` §3, §5, §6, §7.

**Depends on:** Phase 1 may ship first, but Phase 2 is code-independent of it.

## Global Constraints

- Branch off and PR into **`nightly`** (promotion ladder; never `main`).
- **Schema migration discipline:** the next free version on `nightly` is **V24** (current tip is `v23_audiobook_abs_provenance`). Re-confirm no sibling branch claimed V24 before committing; run the `schema-migration-reviewer` agent. Never edit a shipped migration.
- `segment_key` is **nullable**; existing/imported rows stay `NULL` → fall back to chapter scoping (imported multi-track read-along unchanged).
- `ReaderActiveBlockResolver` lives in `Shared/` and must NOT import `EchoCore` (the macOS target doesn't link it). The iOS reader (`ReaderTab`/`ReaderFeedViewModel`) and macOS reader (`MacReaderFeedView`) share it — keep them in parity (run `cross-platform-parity-reviewer`).
- Cache: bump `NarrationFileNaming.renderVersion` 6→7 so the existing `staleVoiceFiles` sweep deletes orphaned per-chapter files for free and every book re-renders once into segments.
- 16 GB machine: `make build-tests` once, then `make test-only FILTER=…`; never parallel/concurrent `xcodebuild`.
- Conventional Commits; footer `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.

---

### Task 1: `NarrationSegmentPlanner` (pure, adaptive sizing)

**Files:**
- Create: `EchoCore/Services/Narration/NarrationSegmentPlanner.swift`
- Test: `EchoTests/NarrationSegmentPlannerTests.swift`

**Interfaces:**
- Consumes: `NarrationChapterPlanner.PlannedChapter { index, displayNumber, blocks: [EPubBlockRecord] }`.
- Produces: `NarrationSegmentPlanner.PlannedSegment { chapterIndex: Int, chapterDisplayNumber: Int, segmentIndex: Int, blocks: [EPubBlockRecord] }` and `static func segments(for chapter: PlannedChapter, isFirstChapterOfBook: Bool) -> [PlannedSegment]` and `static func plan(_ chapters: [PlannedChapter]) -> [PlannedSegment]`.

Sizing policy (char-based estimate, since real audio duration is unknown pre-synthesis): estimate a block's audio seconds as `max(1, chars / 14)` (~14 chars/sec ≈ the device logs: ~200 tokens≈12 s, ~3.5 chars/token). The **first segment of the book** closes once estimated audio ≥ **8 s** (so ~1–3 blocks). Every later segment closes once estimated audio ≥ **50 s**. A segment always contains ≥1 block.

- [ ] **Step 1: Write the failing tests**

Create `EchoTests/NarrationSegmentPlannerTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct NarrationSegmentPlannerTests {
    private func block(_ id: String, chars: Int, chapter: Int, seq: Int) -> EPubBlockRecord {
        EPubBlockRecord.makeForTest(
            id: id, audiobookID: "b", text: String(repeating: "a", count: chars),
            chapterIndex: chapter, sequenceIndex: seq)
    }

    @Test func firstChapterFirstSegmentIsSmall() {
        // Five ~150-char blocks (~10 s each). First segment should close after the
        // first block (≥8 s), so first audio is fast.
        let blocks = (0..<5).map { block("x\($0)", chars: 150, chapter: 0, seq: $0) }
        let chapter = NarrationChapterPlanner.PlannedChapter(
            index: 0, displayNumber: 1, blocks: blocks)
        let segs = NarrationSegmentPlanner.segments(for: chapter, isFirstChapterOfBook: true)
        #expect(segs.first?.blocks.count == 1)
        #expect(segs.first?.segmentIndex == 0)
        #expect(segs.allSatisfy { $0.chapterIndex == 0 && $0.chapterDisplayNumber == 1 })
        // segmentIndex is contiguous from 0.
        #expect(segs.map(\.segmentIndex) == Array(0..<segs.count))
    }

    @Test func laterChapterFirstSegmentIsLarge() {
        // Not the first chapter of the book → first segment uses the 50 s target,
        // so a handful of ~10 s blocks pack into one segment.
        let blocks = (0..<3).map { block("y\($0)", chars: 150, chapter: 2, seq: $0) }
        let chapter = NarrationChapterPlanner.PlannedChapter(
            index: 2, displayNumber: 3, blocks: blocks)
        let segs = NarrationSegmentPlanner.segments(for: chapter, isFirstChapterOfBook: false)
        #expect(segs.count == 1)
        #expect(segs[0].blocks.count == 3)
    }

    @Test func everySegmentHasAtLeastOneBlockAndNoneAreLost() {
        let blocks = (0..<7).map { block("z\($0)", chars: 800, chapter: 1, seq: $0) }
        let chapter = NarrationChapterPlanner.PlannedChapter(
            index: 1, displayNumber: 2, blocks: blocks)
        let segs = NarrationSegmentPlanner.segments(for: chapter, isFirstChapterOfBook: false)
        #expect(segs.allSatisfy { !$0.blocks.isEmpty })
        #expect(segs.flatMap { $0.blocks.map(\.id) } == blocks.map(\.id))
    }

    @Test func planMarksOnlyTheFirstChapterAsBookStart() {
        let c0 = NarrationChapterPlanner.PlannedChapter(
            index: 0, displayNumber: 1, blocks: [block("a", chars: 150, chapter: 0, seq: 0)])
        let c1 = NarrationChapterPlanner.PlannedChapter(
            index: 1, displayNumber: 2,
            blocks: (0..<4).map { block("b\($0)", chars: 150, chapter: 1, seq: $0) })
        let segs = NarrationSegmentPlanner.plan([c0, c1])
        // Chapter 1 (book start) → its single block is its own segment.
        #expect(segs.filter { $0.chapterIndex == 0 }.count == 1)
        // Chapter 2 (not book start) → ~40 s of blocks pack into one segment.
        #expect(segs.filter { $0.chapterIndex == 1 }.count == 1)
    }
}
```

> If `EPUBBlockRecord.makeForTest` doesn't already exist with these parameters, check the existing narration/planner tests for the established test factory and use that instead — match the project's existing helper rather than adding a new one.

- [ ] **Step 2: Run tests to verify they fail**

Run: `make build-tests && make test-only FILTER=EchoTests/NarrationSegmentPlannerTests`
Expected: FAIL to compile — `NarrationSegmentPlanner` undefined.

- [ ] **Step 3: Write the planner**

Create `EchoCore/Services/Narration/NarrationSegmentPlanner.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Splits each narratable chapter into ordered render *segments* — small enough
/// that the first one finishes fast (so playback starts in seconds), large enough
/// afterward to keep the file/track count bounded. Pure, so it's unit-tested
/// without the TTS engine. Downstream of `NarrationChapterPlanner`.
enum NarrationSegmentPlanner {
    /// One render unit: a contiguous run of a chapter's blocks. `chapterIndex` /
    /// `chapterDisplayNumber` carry the owning chapter (for titles, outline,
    /// export coalescing); `segmentIndex` is 0-based within the chapter.
    struct PlannedSegment: Equatable {
        let chapterIndex: Int
        let chapterDisplayNumber: Int
        let segmentIndex: Int
        let blocks: [EPubBlockRecord]
    }

    /// ~chars per second of synthesized audio (from device logs: ~200 tokens ≈
    /// 12 s, ~3.5 chars/token → ~14 chars/s). Only used to *estimate* segment
    /// size before synthesis; exact durations come from the render.
    private static let charsPerSecond = 14.0
    private static let firstSegmentTargetSeconds = 8.0
    private static let laterSegmentTargetSeconds = 50.0

    static func plan(_ chapters: [NarrationChapterPlanner.PlannedChapter]) -> [PlannedSegment] {
        chapters.enumerated().flatMap { offset, chapter in
            segments(for: chapter, isFirstChapterOfBook: offset == 0)
        }
    }

    static func segments(
        for chapter: NarrationChapterPlanner.PlannedChapter, isFirstChapterOfBook: Bool
    ) -> [PlannedSegment] {
        var result: [PlannedSegment] = []
        var current: [EPubBlockRecord] = []
        var currentSeconds = 0.0
        var segmentIndex = 0

        func target() -> Double {
            // Only the very first segment of the book gets the tiny target.
            (isFirstChapterOfBook && segmentIndex == 0)
                ? firstSegmentTargetSeconds : laterSegmentTargetSeconds
        }
        func flush() {
            guard !current.isEmpty else { return }
            result.append(PlannedSegment(
                chapterIndex: chapter.index,
                chapterDisplayNumber: chapter.displayNumber,
                segmentIndex: segmentIndex,
                blocks: current))
            segmentIndex += 1
            current = []
            currentSeconds = 0
        }

        for block in chapter.blocks {
            current.append(block)
            let chars = Double((block.text ?? "").count)
            currentSeconds += max(1.0, chars / charsPerSecond)
            if currentSeconds >= target() { flush() }
        }
        flush()  // trailing partial segment
        return result
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `make test-only FILTER=EchoTests/NarrationSegmentPlannerTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/Narration/NarrationSegmentPlanner.swift EchoTests/NarrationSegmentPlannerTests.swift
git commit -m "feat(narration): NarrationSegmentPlanner — adaptive render-unit splitting

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: Segment-aware cache filenames + parser

**Files:**
- Modify: `EchoCore/Services/Narration/NarrationFileNaming.swift`
- Test: `EchoTests/NarrationFileNamingTests.swift` (create if absent)

**Interfaces:**
- Produces: `segmentFileName(audiobookID:chapterIndex:segmentIndex:voice:) -> String`; `segmentLocation(fromFileName:) -> (chapterIndex: Int, segmentIndex: Int)?`; existing `chapterIndex(fromFileName:)` keeps working for `-ch<N>` (returns the chapter even from a segment name). `renderVersion` becomes 7.

Filename shape: `<safeToken>-ch<idx>-s<seg>-<voice>-v7.m4a`.

- [ ] **Step 1: Write the failing tests**

Create/extend `EchoTests/NarrationFileNamingTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@Suite struct NarrationFileNamingTests {
    @Test func segmentFileNameRoundTrips() {
        let name = NarrationFileNaming.segmentFileName(
            audiobookID: "file:///b/", chapterIndex: 3, segmentIndex: 2, voice: VoiceID("af_heart"))
        #expect(name.contains("-ch3-s2-af_heart-v7.m4a"))
        let loc = NarrationFileNaming.segmentLocation(fromFileName: name)
        #expect(loc?.chapterIndex == 3)
        #expect(loc?.segmentIndex == 2)
        // Chapter parser still recovers the chapter from a segment file.
        #expect(NarrationFileNaming.chapterIndex(fromFileName: name) == 3)
    }

    @Test func segmentLocationRejectsNonSegmentNames() {
        #expect(NarrationFileNaming.segmentLocation(fromFileName: "nope.m4a") == nil)
    }
}
```

- [ ] **Step 2: Run to verify fail**

Run: `make build-tests && make test-only FILTER=EchoTests/NarrationFileNamingTests`
Expected: FAIL to compile — `segmentFileName`/`segmentLocation` undefined.

- [ ] **Step 3: Implement**

In `NarrationFileNaming.swift`: bump `renderVersion` to `7` (extend the doc comment: `v7 = segment render units (one file per segment); audio bytes unchanged per block, but the cache layout changed, so v6 per-chapter files are swept and re-rendered once`). Add:

```swift
static func segmentFileName(
    audiobookID: String, chapterIndex: Int, segmentIndex: Int, voice: VoiceID
) -> String {
    "\(safeToken(audiobookID))-ch\(chapterIndex)-s\(segmentIndex)-\(voice.rawValue)-v\(renderVersion).m4a"
}

/// Recovers `(chapterIndex, segmentIndex)` from a `segmentFileName`, or `nil`.
static func segmentLocation(fromFileName fileName: String) -> (chapterIndex: Int, segmentIndex: Int)? {
    guard let chMarker = fileName.range(of: "-ch") else { return nil }
    let chDigits = fileName[chMarker.upperBound...].prefix { $0.isNumber }
    guard let chapter = Int(chDigits) else { return nil }
    guard let sMarker = fileName.range(of: "-s", range: chMarker.upperBound..<fileName.endIndex)
    else { return nil }
    let sDigits = fileName[sMarker.upperBound...].prefix { $0.isNumber }
    guard let segment = Int(sDigits) else { return nil }
    return (chapter, segment)
}
```

> `chapterIndex(fromFileName:)` already matches `-ch<digits>` and ignores the rest, so it still returns the chapter from a segment name — no change needed (the round-trip test covers it).

- [ ] **Step 4: Run to verify pass**

Run: `make test-only FILTER=EchoTests/NarrationFileNamingTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/Narration/NarrationFileNaming.swift EchoTests/NarrationFileNamingTests.swift
git commit -m "feat(narration): segment-aware cache filenames; renderVersion 6->7

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Schema V24 — `timeline_item.segment_key`

**Files:**
- Create: `Shared/Database/Migrations/Schema_V24.swift`
- Modify: `Shared/Database/DatabaseService.swift` (register after V23, ~line 115)
- Test: `EchoTests/SchemaV24Tests.swift`

**Interfaces:**
- Produces: a nullable `segment_key TEXT` column on `timeline_item`; existing rows `NULL`.

- [ ] **Step 1: Write the failing test**

Create `EchoTests/SchemaV24Tests.swift` (mirror an existing `SchemaV*Tests`; the pattern is a `DatabaseService(inMemory:)` whose migrator has run, then assert the column exists):

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB
import Testing

@testable import Echo

@Suite struct SchemaV24Tests {
    @Test func timelineItemHasNullableSegmentKey() throws {
        let service = try DatabaseService(inMemory: true)
        try service.writer.read { db in
            let columns = try db.columns(in: "timeline_item")
            let segment = columns.first { $0.name == "segment_key" }
            #expect(segment != nil)
            #expect(segment?.isNotNull == false)  // nullable
        }
    }
}
```

- [ ] **Step 2: Run to verify fail**

Run: `make build-tests && make test-only FILTER=EchoTests/SchemaV24Tests`
Expected: FAIL — column `segment_key` absent.

- [ ] **Step 3: Write the migration + register it**

Create `Shared/Database/Migrations/Schema_V24.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB

/// V24 — per-segment read-along scope key. Narration renders a chapter as
/// multiple segment files; each `timeline_item` row records the segment it
/// belongs to so the reader can scope the active block to the currently-playing
/// segment (chapter scope alone collides across a chapter's segments). Nullable:
/// imported/aligned books leave it NULL and keep chapter-level scoping.
enum Schema_V24 {
    nonisolated static func migrate(_ db: Database) throws {
        try db.alter(table: "timeline_item") { t in
            t.add(column: "segment_key", .text)
        }
    }
}
```

In `DatabaseService.swift`, register immediately after the V23 block (~line 115):

```swift
migrator.registerMigration("v24_timeline_item_segment_key") { db in
    try Schema_V24.migrate(db)
}
```

- [ ] **Step 4: Run to verify pass**

Run: `make test-only FILTER=EchoTests/SchemaV24Tests`
Expected: PASS.

- [ ] **Step 5: Run the schema reviewer + commit**

Run the `schema-migration-reviewer` agent over the change (version collision, registration order, tests). Then:

```bash
git add Shared/Database/Migrations/Schema_V24.swift Shared/Database/DatabaseService.swift EchoTests/SchemaV24Tests.swift
git commit -m "feat(db): V24 add nullable timeline_item.segment_key for segment read-along scope

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: `TimelineItem`/DAO — persist `segment_key`

**Files:**
- Modify: `Shared/Database/TimelineItem.swift` (add the property + coding key)
- Modify: the timeline write path so narration can stamp a segment key — add `TimelineDAO.setSegmentKey(db:audiobookID:blockIDs:segmentKey:)`
- Test: `EchoTests/TimelineSegmentKeyTests.swift`

**Interfaces:**
- Consumes: Schema V24's `segment_key` column.
- Produces: `TimelineItem.segmentKey: String?`; `TimelineDAO.setSegmentKey(db:audiobookID:blockIDs:segmentKey:)`.

- [ ] **Step 1: Write the failing test**

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB
import Testing

@testable import Echo

@Suite struct TimelineSegmentKeyTests {
    @Test func setSegmentKeyStampsOnlyTheGivenBlocks() throws {
        let service = try DatabaseService(inMemory: true)
        try service.writer.write { db in
            // minimal audiobook + two timeline_item rows
            try db.execute(sql: "INSERT INTO audiobook (id) VALUES ('b')")
            for id in ["x", "y"] {
                try db.execute(
                    sql: "INSERT INTO timeline_item (audiobook_id, epub_block_id, audio_start_time) VALUES ('b', ?, 0)",
                    arguments: [id])
            }
            try TimelineDAO.setSegmentKey(
                db: db, audiobookID: "b", blockIDs: ["x"], segmentKey: "0-0")
            let keyForX = try String.fetchOne(
                db, sql: "SELECT segment_key FROM timeline_item WHERE epub_block_id = 'x'")
            let keyForY = try String.fetchOne(
                db, sql: "SELECT segment_key FROM timeline_item WHERE epub_block_id = 'y'")
            #expect(keyForX == "0-0")
            #expect(keyForY == nil)
        }
    }
}
```

> Adjust the `audiobook` INSERT to satisfy its NOT NULL columns — check `Schema_V1` for the table's required columns and supply them (the existing `*DAOTests` show the minimal insert this project uses).

- [ ] **Step 2: Run to verify fail** — `make build-tests && make test-only FILTER=EchoTests/TimelineSegmentKeyTests` → FAIL (`segmentKey`/`setSegmentKey` undefined).

- [ ] **Step 3: Implement**

In `TimelineItem.swift`, add the stored property and its coding key (`segment_key`), defaulting to `nil`, mirroring how `narrationVoice`/other optionals are declared in the project's records. In `TimelineDAO`, add:

```swift
/// Stamps `segmentKey` onto the timeline rows of `blockIDs` (narration scope).
static func setSegmentKey(
    db: Database, audiobookID: String, blockIDs: [String], segmentKey: String
) throws {
    guard !blockIDs.isEmpty else { return }
    let placeholders = databaseQuestionMarks(count: blockIDs.count)
    try db.execute(
        sql: """
            UPDATE timeline_item SET segment_key = ?
            WHERE audiobook_id = ? AND epub_block_id IN (\(placeholders))
            """,
        arguments: StatementArguments([segmentKey, audiobookID] + blockIDs))
}
```

> `databaseQuestionMarks(count:)` is GRDB's helper; if the project wraps it differently, follow the existing `IN (…)` query style in `TimelineDAO`.

- [ ] **Step 4: Run to verify pass** — `make test-only FILTER=EchoTests/TimelineSegmentKeyTests` → PASS.

- [ ] **Step 5: Commit**

```bash
git add Shared/Database/TimelineItem.swift Shared/Database/TimelineDAO.swift EchoTests/TimelineSegmentKeyTests.swift
git commit -m "feat(db): TimelineItem.segmentKey + TimelineDAO.setSegmentKey

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Renderer — `renderSegment` writing one file + stamping `segment_key`

**Files:**
- Modify: `EchoCore/Services/Narration/NarrationService.swift` (generalize `renderChapter` → `renderSegment`)
- Test: `EchoTests/NarrationServiceTests.swift` (add segment cases; reuse the existing `MockTTSEngine` + in-memory DB harness)

**Interfaces:**
- Consumes: `NarrationSegmentPlanner.PlannedSegment`; `NarrationFileNaming.segmentFileName`; `TimelineDAO.setSegmentKey`.
- Produces: `func renderSegment(chapterIndex:chapterDisplayNumber:segmentIndex:blocks:voice:onBlockProgress:) async throws`. The `TrackRecord.id` becomes `syn-<book>-ch<idx>-s<seg>`, `sortOrder = chapterIndex * 1000 + segmentIndex`, `title = "Chapter <displayNumber>"`. `segment_key` written = `"<chapterIndex>-<segmentIndex>"`.

This generalizes the existing `renderChapter`. Anchors stay 0-based per file (the cursor already resets per call). After the existing timeline recalc/word-timing block, stamp the segment key.

- [ ] **Step 1: Write the failing test** — render two segments of one chapter and assert two files/tracks, distinct `segment_key`s, and per-segment 0-based anchors.

```swift
@Test func renderSegmentWritesOneFilePerSegmentWithDistinctKeys() async throws {
    let harness = try NarrationServiceTestHarness()  // existing helper: in-mem DB + MockTTSEngine + temp cache dir
    let svc = harness.service(audiobookID: "b")
    let seg0 = [harness.block("a", chapter: 0, seq: 0), harness.block("b", chapter: 0, seq: 1)]
    let seg1 = [harness.block("c", chapter: 0, seq: 2)]
    try await svc.renderSegment(
        chapterIndex: 0, chapterDisplayNumber: 1, segmentIndex: 0, blocks: seg0, voice: VoiceID("af_heart"))
    try await svc.renderSegment(
        chapterIndex: 0, chapterDisplayNumber: 1, segmentIndex: 1, blocks: seg1, voice: VoiceID("af_heart"))

    let tracks = try harness.tracks(audiobookID: "b")
    #expect(tracks.count == 2)
    #expect(tracks.map(\.id) == ["syn-b-ch0-s0", "syn-b-ch0-s1"])
    #expect(tracks.allSatisfy { $0.title == "Chapter 1" })

    let keys = try harness.segmentKeys(audiobookID: "b")  // SELECT DISTINCT segment_key
    #expect(Set(keys) == ["0-0", "0-1"])
}
```

> Use whatever harness/factory `NarrationServiceTests` already defines. If it tests `renderChapter` directly, model the new test on that and adapt to `renderSegment`.

- [ ] **Step 2: Run to verify fail** — `make build-tests && make test-only FILTER=EchoTests/NarrationServiceTests` → FAIL (`renderSegment` undefined).

- [ ] **Step 3: Implement `renderSegment`**

Rename/generalize `renderChapter` to `renderSegment`. Changes vs the current body:
- Signature gains `segmentIndex: Int` and `chapterDisplayNumber: Int` (replacing the `chapterNumber` derivation); the `onBlockProgress` param from Phase 1 Task 2 carries over.
- File URL uses `NarrationFileNaming.segmentFileName(audiobookID:chapterIndex:segmentIndex:voice:)`.
- `TrackRecord`: `id = "syn-\(audiobookID)-ch\(chapterIndex)-s\(segmentIndex)"`, `title = "Chapter \(chapterDisplayNumber)"`, `sortOrder = chapterIndex * 1000 + segmentIndex`.
- Keep the anchor loop, lead-out pad, atomic DB write, and the post-write `recalculateTimeline(anchoredOnly: true, materializeWordTimings: false)` + `WordTimingMaterializer.materializeChapter(...)` exactly as-is (they operate on this segment's `spoken` blocks).
- **After** that recalc block (still inside the method, after the `do { … } catch { … }`), stamp the segment key in one write:

```swift
let segmentKey = "\(chapterIndex)-\(segmentIndex)"
let stampBlockIDs = spoken.map(\.id)
try? await db.write { db in
    try TimelineDAO.setSegmentKey(
        db: db, audiobookID: audiobookID, blockIDs: stampBlockIDs, segmentKey: segmentKey)
}
```

> `sortOrder = chapterIndex * 1000 + segmentIndex` assumes <1000 segments per chapter — true for the ~50 s target (a 10-hour chapter is ~720 segments). If a future chapter could exceed that, widen the multiplier; for now 1000 is safe and asserted by Task 1's sizing.

- [ ] **Step 4: Run to verify pass** — `make test-only FILTER=EchoTests/NarrationServiceTests` → PASS.

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/Narration/NarrationService.swift EchoTests/NarrationServiceTests.swift
git commit -m "feat(narration): render per-segment files + stamp timeline segment_key

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: Read-along resolver — segment scoping

**Files:**
- Modify: `EchoCore/Services/ReaderActiveBlockResolver.swift` (or its `Shared/` path — confirm; it must not import `EchoCore`)
- Test: `EchoTests/ReaderActiveBlockResolverTests.swift` (extend)

**Interfaces:**
- Produces: `TimelineRow` gains `segmentKey: String?`; `activeBlockID(in:time:currentTrackSegmentKey:currentTrackChapterIndices:)` — when `currentTrackSegmentKey != nil`, filter rows by `row.segmentKey == currentTrackSegmentKey`; else the existing chapter logic. Add `static func segmentKey(forChapter:segment:) -> String` so writer and reader agree on the `"<ch>-<seg>"` format.

- [ ] **Step 1: Write the failing test** — the exact collision case: two segments of chapter 0, both with a block near 5 s; segment-scoped resolution must pick the right one.

```swift
@Test func segmentScopeResolvesTheCorrectBlockAcrossSameChapterSegments() {
    // Both rows are chapter 0, both 0-based; seg0 block at [0,6), seg1 block at [0,6).
    let cache: [ReaderActiveBlockResolver.TimelineRow] = [
        (start: 0, end: 6, blockID: "seg0blk", chapterIndex: 0, segmentKey: "0-0"),
        (start: 0, end: 6, blockID: "seg1blk", chapterIndex: 0, segmentKey: "0-1"),
    ]
    // Playing segment 1 at t=5 → must be seg1blk, NOT seg0blk (the collision).
    #expect(ReaderActiveBlockResolver.activeBlockID(
        in: cache, time: 5, currentTrackSegmentKey: "0-1", currentTrackChapterIndices: [0]) == "seg1blk")
    #expect(ReaderActiveBlockResolver.activeBlockID(
        in: cache, time: 5, currentTrackSegmentKey: "0-0", currentTrackChapterIndices: [0]) == "seg0blk")
}

@Test func nilSegmentKeyFallsBackToChapterScope() {
    let cache: [ReaderActiveBlockResolver.TimelineRow] = [
        (start: 0, end: 6, blockID: "c0", chapterIndex: 0, segmentKey: nil),
        (start: 0, end: 6, blockID: "c1", chapterIndex: 1, segmentKey: nil),
    ]
    #expect(ReaderActiveBlockResolver.activeBlockID(
        in: cache, time: 3, currentTrackSegmentKey: nil, currentTrackChapterIndices: [1]) == "c1")
}
```

> Updating `TimelineRow` (a tuple typealias) to gain `segmentKey` will require touching every existing `TimelineRow` literal in this test file and in `ReaderFeedViewModel`. Add `segmentKey: nil` to all existing literals as part of this task; the compiler will list each site.

- [ ] **Step 2: Run to verify fail** — `make build-tests && make test-only FILTER=EchoTests/ReaderActiveBlockResolverTests` → FAIL to compile (tuple arity + new param).

- [ ] **Step 3: Implement**

- Extend the `TimelineRow` typealias: `(start: TimeInterval, end: TimeInterval, blockID: String, chapterIndex: Int?, segmentKey: String?)`.
- Add the new `activeBlockID` overload (keep the old signature delegating with `currentTrackSegmentKey: nil` so non-narration callers are untouched):

```swift
static func segmentKey(forChapter chapter: Int, segment: Int) -> String { "\(chapter)-\(segment)" }

static func activeBlockID(
    in cache: [TimelineRow],
    time: TimeInterval,
    currentTrackSegmentKey: String?,
    currentTrackChapterIndices: Set<Int>?
) -> String? {
    if let segmentKey = currentTrackSegmentKey {
        for row in cache where row.segmentKey == segmentKey {
            if time >= row.start && time < row.end { return row.blockID }
        }
        return nil
    }
    return activeBlockID(
        in: cache, time: time, currentTrackChapterIndices: currentTrackChapterIndices)
}
```

(The existing `activeBlockID(in:time:currentTrackChapterIndices:)` stays as the fallback; just add `segmentKey` to its `TimelineRow` destructuring where needed — the field is ignored on that path.)

- [ ] **Step 4: Run to verify pass** — `make test-only FILTER=EchoTests/ReaderActiveBlockResolverTests` → PASS.

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/ReaderActiveBlockResolver.swift EchoTests/ReaderActiveBlockResolverTests.swift
git commit -m "feat(reader): segment-scoped active-block resolution (read-along across segments)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 7: Reader wiring — load `segment_key`, derive current segment, scope iOS + macOS

**Files:**
- Modify: `EchoCore/ViewModels/ReaderFeedViewModel.swift` (the timeline query ~243-282 + `updateActiveBlock` ~372)
- Modify: `EchoCore/Views/ReaderTab.swift` (`currentTrackChapterIndices` ~382 → also compute the segment key)
- Modify: the macOS reader (`MacReaderFeedView` / its equivalent) for parity
- Test: covered by Task 6 (resolver) + a small VM test if the harness allows; otherwise rely on the resolver tests + manual device check.

**Interfaces:**
- Consumes: `NarrationFileNaming.segmentLocation(fromFileName:)`, `ReaderActiveBlockResolver.segmentKey(forChapter:segment:)`.

- [ ] **Step 1: Load `segment_key` into the timeline cache.** In `ReaderFeedViewModel`'s timeline SQL (`SELECT ti.audio_start_time, …`), add `ti.segment_key` to the columns; in the row loop, read `let segmentKey: String? = row["segment_key"]` and append it to the `TimelineRow` tuple.

- [ ] **Step 2: Compute the current segment key from the playing track.** In `ReaderTab.swift`, alongside `playingChapterIndex`, derive:

```swift
var currentSegmentKey: String?
if tracks.indices.contains(currentIndex),
   let loc = NarrationFileNaming.segmentLocation(
       fromFileName: tracks[currentIndex].url.lastPathComponent) {
    currentSegmentKey = ReaderActiveBlockResolver.segmentKey(
        forChapter: loc.chapterIndex, segment: loc.segmentIndex)
}
```

Pass it through to `updateActiveBlock`.

- [ ] **Step 3: Thread the segment key through `updateActiveBlock`.** Change its signature to `updateActiveBlock(time:currentTrackSegmentKey:currentTrackChapterIndices:)` and call the new resolver overload. Update both call sites in `ReaderTab.swift` (~228, ~235) and the macOS reader.

> `ReaderActiveBlockResolver` is in `Shared/` and can't import `EchoCore`/`NarrationFileNaming`; the filename→segment parse stays in the *reader* layer (which already does the `chapterIndex(fromFileName:)` parse), and only the resulting `String?` key crosses into the shared resolver — same boundary the chapter scope already respects.

- [ ] **Step 4: Build both platforms.**

Run: `make build-tests`
Expected: BUILD SUCCEEDED (iOS + macOS). Fix every `TimelineRow`/`updateActiveBlock` call the compiler flags.

- [ ] **Step 5: Run reader + resolver suites.**

Run: `make test-only FILTER=EchoTests/ReaderActiveBlockResolverTests` and any `ReaderFeedViewModel*` suite.
Expected: PASS.

- [ ] **Step 6: Run `cross-platform-parity-reviewer`** over the reader/resolver change, then commit.

```bash
git add EchoCore/ViewModels/ReaderFeedViewModel.swift EchoCore/Views/ReaderTab.swift <macOS reader file>
git commit -m "feat(reader): scope read-along to the current narration segment (iOS+macOS)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 8: Orchestration — render & queue by segment, play after segment 1

**Files:**
- Modify: `EchoCore/ViewModels/PlayerModel+Narration.swift` (`startNarrationPlayback` render loop ~131-309)
- Test: `EchoTests/NarrationRenderPolicyTests.swift` / a planner-integration test where feasible; otherwise manual device verification (the orchestration is `@MainActor` UI-coupled).

**Interfaces:**
- Consumes: `NarrationSegmentPlanner.plan`, `renderSegment`, `NarrationFileNaming.segmentFileName`.

- [ ] **Step 1: Replace the chapter plan with a segment plan.** After `let plan = NarrationChapterPlanner.plan(from: blocks)` (~131), build `let segments = NarrationSegmentPlanner.plan(plan)`. The resume split (`resume` / `beforeResume`) now operates on **segments**: add `NarrationSegmentPlanner`-aware resume that, given a resume *segment* (chapter+segment), returns the forward set (that segment → end) and the earlier set — or, simplest, resume at the first segment of the resume *chapter* (coarser but correct) and keep the existing chapter-based `resume`/`beforeResume` by grouping segments by chapter. **Decision:** resume at the resume chapter's first segment — map the saved track's filename via `segmentLocation`, take its `chapterIndex`, and start the forward set at the first segment whose `chapterIndex == resumeChapter`.

- [ ] **Step 2: Iterate segments.** Replace the `for (offset, chapter) in chapters.enumerated()` loop body so each iteration renders/queues a **segment**: file URL via `segmentFileName(audiobookID:chapterIndex:segmentIndex:voice:)`; `renderSegment(chapterIndex:chapterDisplayNumber:segmentIndex:blocks:voice:onBlockProgress:)`; the `offset == 0` branch (start playback) now fires after **segment 0 of the first chapter** finalizes — i.e. ~5 s in. The look-ahead backpressure (`NarrationRenderPolicy.shouldPauseRender`) and book-switch/cancellation guards are unchanged (finer unit). Track title = `"Chapter \(segment.chapterDisplayNumber)"`.

- [ ] **Step 3: Stale-file sweep already covered.** The `staleVoiceFiles` call at startup (~63-71) now sweeps v6 per-chapter files for free (renderVersion bumped to 7 in Task 2). No change.

- [ ] **Step 4: Build + run.**

Run: `make build-tests` → BUILD SUCCEEDED. Then `make test-only FILTER=EchoTests/NarrationRenderPolicyTests` → PASS.

- [ ] **Step 5: On-device verification (manual).** Narrate the test book (`Eating and weight loss`). Confirm in Console: `Chapter 1: synthesizing N block(s)…` now appears for a **small first segment**, and playback starts within a few seconds (not 73 s). Read-along: scrub within chapter 1 across the segment boundary and confirm the highlight tracks the correct block.

- [ ] **Step 6: Commit**

```bash
git add EchoCore/ViewModels/PlayerModel+Narration.swift
git commit -m "feat(narration): render+queue by segment; first audio after segment 1

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 9: m4b export — coalesce segments into chapter markers

**Files:**
- Modify: `EchoCore/Services/Export/*` (the narration `ExportSource` / `NarrationCacheSource` that lists per-chapter files)
- Test: `EchoTests/AudioExportServiceTests.swift` (or the export source's existing test)

**Interfaces:**
- Consumes: `NarrationFileNaming.segmentLocation`.

- [ ] **Step 1: Write the failing test** — an export source over a book with chapters {0:[s0,s1], 1:[s0]} produces **2** chapter markers (one per chapter), in order, with chapter 0's marker spanning both its segment files' durations.

```swift
@Test func exportCoalescesSegmentsIntoOneMarkerPerChapter() throws {
    // Build a NarrationCacheSource over fake segment files (or the existing test
    // double the export suite uses) for ch0-s0, ch0-s1, ch1-s0.
    let markers = try makeNarrationExportSource(segments: [(0,0),(0,1),(1,0)]).chapterMarkers()
    #expect(markers.count == 2)
    #expect(markers.map(\.title) == ["Chapter 1", "Chapter 2"])
    // ch0 marker starts at 0; ch1 marker starts after both ch0 segments.
    #expect(markers[0].startTime == 0)
    #expect(markers[1].startTime > 0)
}
```

> Match the export suite's existing test factory + the real `chapterMarkers()`/marker type names. If the export source currently maps 1 file → 1 marker, this test pins the new grouping behavior.

- [ ] **Step 2: Run to verify fail** — `make build-tests && make test-only FILTER=EchoTests/AudioExportServiceTests` → FAIL.

- [ ] **Step 3: Implement coalescing.** Where the export source enumerates narration files and emits one marker per file, group the ordered segment files by `segmentLocation(...).chapterIndex` and emit one marker per chapter at the cumulative start offset of its first segment, titled `"Chapter \(displayNumber)"`. The concatenated audio order is unchanged (segments already sort by `chapterIndex*1000+segmentIndex`).

- [ ] **Step 4: Run to verify pass** — `make test-only FILTER=EchoTests/AudioExportServiceTests` → PASS.

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/Export EchoTests/AudioExportServiceTests.swift
git commit -m "feat(export): coalesce narration segments into one m4b chapter marker each

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-review notes (already applied)

- **Spec coverage:** §5a planner→T1; §5b naming/renderer→T2,T5; §6 segment_key→T3,T4,T6,T7; §5c orchestration→T8; §7 resume→T8 step1, export→T9, outline/exclusion→unchanged (chapter-level, no task needed). ✅
- **Type consistency:** `segment_key` string format `"<ch>-<seg>"` is produced by `ReaderActiveBlockResolver.segmentKey(forChapter:segment:)` and the renderer's `"\(chapterIndex)-\(segmentIndex)"` — **unify** the renderer to call `ReaderActiveBlockResolver.segmentKey(...)` so they can't drift (do this in T5 step 3). `renderSegment` signature is identical in T5 (definition) and T8 (call). `TimelineRow` gains `segmentKey` consistently in T6/T7. ✅
- **Migration:** V24 nullable; imported books unaffected (T6 `nilSegmentKeyFallsBackToChapterScope`). ✅
- **Open confirmations (verify at implementation, not placeholders):** the exact `audiobook` test-insert columns (T4), the export source's marker type/method names (T9), and the macOS reader filename (T7) — all resolved by reading the cited existing test/file before writing.

## Risks

- **Resume granularity** (T8) is intentionally coarsened to "resume chapter's first segment" to avoid a segment-precise resume rewrite; revisit only if users report losing intra-chapter position.
- **`sortOrder` multiplier** assumes <1000 segments/chapter (safe at the 50 s target).
- **renderVersion 6→7** re-renders every narrated book once — acceptable (segmentation changes layout regardless; few books are narrated yet).
