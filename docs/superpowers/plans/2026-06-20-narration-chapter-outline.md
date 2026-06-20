# Narration Chapter Outline + Tap-to-Exclude — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show the full EPUB chapter outline on the playlist page for narration books, and let the user tap a chapter to exclude it from narration (greyed, never synthesized), reusing the existing `is_hidden` axis.

**Architecture:** A pure `NarrationOutlineBuilder` turns the book's EPUB blocks + a file-exists check into `[NarrationOutlineChapter]`. `PlayerModel` exposes `isNarrationBook`, `narrationOutline`, and `toggleNarrationChapterExcluded(chapterIndex:)`, which flips the chapter's blocks via `AlignmentService.hideChapter`/new `unhideChapter`. `PlaylistView` renders the outline for narration books. No schema change — exclusion is the existing `epub_block.is_hidden` column.

**Tech Stack:** Swift 6, SwiftUI, GRDB, Swift Testing.

## Global Constraints

- SPDX header `// SPDX-License-Identifier: GPL-3.0-or-later` MUST be line 1 of every new/edited Swift file (a format hook can reflow files — verify after edits).
- iOS narration code is under `#if os(iOS)`; shared/pure code compiles on iOS + macOS.
- Tests use Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`) and `DatabaseService(inMemory: ())`.
- Build once with `make build-tests`, then iterate with `make test-only FILTER=EchoTests/<Suite>`. Never run two `xcodebuild` invocations concurrently; never enable parallel testing (16 GB machine). The iOS-26 simulator can throw a spurious "Early unexpected exit … never finished bootstrapping" on the FIRST run — re-run once before treating it as a failure.
- The raw EPUB `chapterIndex` is the stable identity (keys the cache file + track id). `displayNumber` is 1-based position among narratable chapters.
- Narration cache files live under `NarrationCache.directory()`; a chapter file is `NarrationFileNaming.chapterFileName(audiobookID:chapterIndex:voice:)`.

---

### Task 1: `unhideChapter` (DAO + AlignmentService)

Adds the include-counterpart to the existing `hideChapter`, so the outline toggle can re-include a chapter.

**Files:**
- Modify: `Shared/Database/DAOs/EPubBlockDAO.swift` (after `hideChapter`, ~line 158)
- Modify: `EchoCore/Services/AlignmentService.swift` (after `hideChapter`, ~line 171)
- Test: `EchoTests/EPubBlockDAOHideTests.swift` (create)

**Interfaces:**
- Produces: `EPubBlockDAO.unhideChapter(chapterIndex: Int, audiobookID: String) throws`
- Produces: `AlignmentService.unhideChapter(chapterIndex: Int) throws`

- [ ] **Step 1: Write the failing test**

Create `EchoTests/EPubBlockDAOHideTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@Suite struct EPubBlockDAOHideTests {
    private func seed(_ db: DatabaseService) throws {
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('bk','Book',0)")
            try db.execute(
                sql: """
                    INSERT INTO epub_block
                      (id, audiobook_id, spine_href, spine_index, block_index,
                       sequence_index, block_kind, text, chapter_index, is_hidden)
                    VALUES ('b0','bk','c.xhtml',0,0,0,'paragraph','hi',2,0),
                           ('b1','bk','c.xhtml',0,1,1,'paragraph','yo',2,0),
                           ('b2','bk','c.xhtml',0,2,2,'paragraph','other',3,0)
                    """)
        }
    }

    @Test func unhideChapterRestoresOnlyThatChapter() throws {
        let db = try DatabaseService(inMemory: ())
        try seed(db)
        let dao = EPubBlockDAO(db: db.writer)
        try dao.hideChapter(chapterIndex: 2, audiobookID: "bk", reason: "skip")
        // Chapter 2 hidden, chapter 3 untouched.
        #expect(try dao.visibleBlocks(for: "bk").map(\.id) == ["b2"])

        try dao.unhideChapter(chapterIndex: 2, audiobookID: "bk")
        #expect(try dao.visibleBlocks(for: "bk").map(\.id).sorted() == ["b0", "b1", "b2"])
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `make build-tests` then `make test-only FILTER=EchoTests/EPubBlockDAOHideTests`
Expected: FAIL — `unhideChapter` not found (compile error).

- [ ] **Step 3: Implement `EPubBlockDAO.unhideChapter`**

In `Shared/Database/DAOs/EPubBlockDAO.swift`, after `hideChapter` (~line 158):

```swift
    func unhideChapter(chapterIndex: Int, audiobookID: String) throws {
        try db.write { db in
            try db.execute(
                sql: """
                    UPDATE epub_block
                    SET is_hidden = 0, hidden_reason = NULL, modified_at = :now
                    WHERE chapter_index = :chapterIndex AND audiobook_id = :audiobookID
                    """,
                arguments: [
                    "now": Self.isoFormatter.string(from: Date()),
                    "chapterIndex": chapterIndex,
                    "audiobookID": audiobookID,
                ]
            )
        }
    }
```

- [ ] **Step 4: Implement `AlignmentService.unhideChapter`**

In `EchoCore/Services/AlignmentService.swift`, after `hideChapter` (~line 171):

```swift
    func unhideChapter(chapterIndex: Int) throws {
        try blockDAO.unhideChapter(chapterIndex: chapterIndex, audiobookID: audiobookID)
        try recalculateTimeline()
    }
```

- [ ] **Step 5: Run to verify it passes**

Run: `make build-tests` then `make test-only FILTER=EchoTests/EPubBlockDAOHideTests`
Expected: PASS (re-run once if the sim early-exits).

- [ ] **Step 6: Commit**

```bash
git add Shared/Database/DAOs/EPubBlockDAO.swift EchoCore/Services/AlignmentService.swift EchoTests/EPubBlockDAOHideTests.swift
git commit -m "feat(narration): add unhideChapter to re-include an excluded chapter"
```

---

### Task 2: `NarrationOutlineChapter` + `NarrationOutlineBuilder` (pure)

The testable core: blocks + a file-exists closure → ordered outline rows with `isExcluded`/`isRendered`/`title`.

**Files:**
- Create: `EchoCore/Services/Narration/NarrationOutlineBuilder.swift`
- Test: `EchoTests/NarrationOutlineBuilderTests.swift`

**Interfaces:**
- Consumes: `NarrationChapterPlanner.plan(from:)` → `[PlannedChapter]` (`index`, `displayNumber`, `blocks`); `EPubBlockRecord` (`chapterIndex`, `isHidden`, `blockKind`, `text`); `EPubBlockRecord.Kind` (`.heading`).
- Produces:
  - `struct NarrationOutlineChapter: Identifiable, Equatable { let chapterIndex: Int; let displayNumber: Int; let title: String; let isExcluded: Bool; let isRendered: Bool; var id: Int { chapterIndex } }`
  - `enum NarrationOutlineBuilder { static func build(allBlocks: [EPubBlockRecord], isRendered: (Int) -> Bool) -> [NarrationOutlineChapter] }`

- [ ] **Step 1: Write the failing test**

Create `EchoTests/NarrationOutlineBuilderTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct NarrationOutlineBuilderTests {
    private func block(
        _ id: String, ch: Int, seq: Int, kind: String = "paragraph",
        text: String?, hidden: Bool = false
    ) -> EPubBlockRecord {
        EPubBlockRecord(
            id: id, audiobookID: "bk", spineHref: "c.xhtml", spineIndex: 0,
            blockIndex: seq, sequenceIndex: seq, blockKind: kind, text: text,
            htmlContent: nil, cardColor: nil, chapterThemeColor: nil, imagePath: nil,
            chapterIndex: ch, isHidden: hidden, hiddenReason: hidden ? "skip" : nil,
            isFrontMatter: false, wordCount: nil, markers: nil, textFormats: nil,
            createdAt: nil, modifiedAt: nil)
    }

    @Test func buildsRowsWithTitleStateAndStableNumbering() {
        let blocks = [
            block("h1", ch: 1, seq: 0, kind: "heading", text: "Beginnings"),
            block("p1", ch: 1, seq: 1, text: "once upon a time"),
            block("p2", ch: 2, seq: 2, text: "second chapter"),  // excluded
            block("h3", ch: 3, seq: 3, kind: "heading", text: "The End"),
            block("p3", ch: 3, seq: 4, text: "final chapter"),
        ]
        // Chapter 2's only block is hidden → excluded.
        let withHidden = blocks.map { b -> EPubBlockRecord in
            guard b.id == "p2" else { return b }
            var m = b; m.isHidden = true; return m
        }
        // Chapter 1 is rendered, others not.
        let rows = NarrationOutlineBuilder.build(
            allBlocks: withHidden, isRendered: { $0 == 1 })

        #expect(rows.map(\.chapterIndex) == [1, 2, 3])
        #expect(rows.map(\.displayNumber) == [1, 2, 3])  // stable, excluded NOT skipped
        #expect(rows[0].title == "Beginnings")           // first heading wins
        #expect(rows[2].title == "The End")
        #expect(rows.map(\.isExcluded) == [false, true, false])
        #expect(rows.map(\.isRendered) == [true, false, false])
    }

    @Test func titleFallsBackToChapterNumber() {
        let rows = NarrationOutlineBuilder.build(
            allBlocks: [block("p1", ch: 5, seq: 0, text: "no heading here")],
            isRendered: { _ in false })
        #expect(rows.count == 1)
        #expect(rows[0].title == "Chapter 1")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `make build-tests` then `make test-only FILTER=EchoTests/NarrationOutlineBuilderTests`
Expected: FAIL — `NarrationOutlineBuilder` / `NarrationOutlineChapter` not found.

- [ ] **Step 3: Implement the builder**

Create `EchoCore/Services/Narration/NarrationOutlineBuilder.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// One row of the narration chapter outline shown on the playlist page.
struct NarrationOutlineChapter: Identifiable, Equatable {
    /// Raw EPUB chapter index — stable identity, keys the cache file + track id.
    let chapterIndex: Int
    /// 1-based position among narratable chapters (does NOT shift on exclude).
    let displayNumber: Int
    /// First heading-block text in the chapter, else "Chapter <displayNumber>".
    let title: String
    /// Every block in the chapter is hidden → not narrated.
    let isExcluded: Bool
    /// A rendered audio file exists for this chapter.
    let isRendered: Bool
    var id: Int { chapterIndex }
}

/// Builds the full narration outline from a book's EPUB blocks. Pure (no DB / no
/// filesystem) — `isRendered` is injected — so it is unit-testable in isolation,
/// mirroring `NarrationChapterPlanner`. Passes ALL blocks (not `visibleBlocks`) so
/// a fully-excluded chapter still appears, greyed, and can be re-included.
enum NarrationOutlineBuilder {
    static func build(
        allBlocks: [EPubBlockRecord], isRendered: (Int) -> Bool
    ) -> [NarrationOutlineChapter] {
        NarrationChapterPlanner.plan(from: allBlocks).map { planned in
            let ordered = planned.blocks.sorted { $0.sequenceIndex < $1.sequenceIndex }
            let title =
                ordered.first(where: {
                    EPubBlockRecord.Kind(rawValue: $0.blockKind) == .heading
                        && ($0.text?.isEmpty == false)
                })?.text ?? "Chapter \(planned.displayNumber)"
            let isExcluded = ordered.allSatisfy { $0.isHidden }
            return NarrationOutlineChapter(
                chapterIndex: planned.index,
                displayNumber: planned.displayNumber,
                title: title,
                isExcluded: isExcluded,
                isRendered: isRendered(planned.index))
        }
    }
}
```

Note: `plan(from:)` keeps a chapter if it has any text-bearing block; it does not filter on `is_hidden`, so excluded chapters survive here.

- [ ] **Step 4: Run to verify it passes**

Run: `make build-tests` then `make test-only FILTER=EchoTests/NarrationOutlineBuilderTests`
Expected: PASS (re-run once if the sim early-exits).

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Services/Narration/NarrationOutlineBuilder.swift EchoTests/NarrationOutlineBuilderTests.swift
git commit -m "feat(narration): pure NarrationOutlineBuilder for the chapter outline"
```

---

### Task 3: Planner guard test — hidden chapter drops from a visible-blocks plan

Pins the invariant the feature relies on: excluding a chapter removes it from what gets rendered.

**Files:**
- Test: `EchoTests/NarrationChapterPlannerTests.swift` (append)

**Interfaces:**
- Consumes: `NarrationChapterPlanner.plan(from:)`, `EPubBlockDAO.visibleBlocks(for:)`.

- [ ] **Step 1: Write the failing-then-passing guard test**

Append to `EchoTests/NarrationChapterPlannerTests.swift` (inside the existing suite). If the suite is a `struct`, add this `@Test`:

```swift
    @Test func hiddenChapterIsAbsentFromVisiblePlan() throws {
        let db = try DatabaseService(inMemory: ())
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('bk','Book',0)")
            try db.execute(
                sql: """
                    INSERT INTO epub_block
                      (id, audiobook_id, spine_href, spine_index, block_index,
                       sequence_index, block_kind, text, chapter_index, is_hidden)
                    VALUES ('a','bk','c.xhtml',0,0,0,'paragraph','keep',1,0),
                           ('b','bk','c.xhtml',0,1,1,'paragraph','skip',2,1)
                    """)
        }
        let visible = try EPubBlockDAO(db: db.writer).visibleBlocks(for: "bk")
        let plan = NarrationChapterPlanner.plan(from: visible)
        #expect(plan.map(\.index) == [1])  // chapter 2 (all-hidden) is gone
    }
```

If `NarrationChapterPlannerTests` is missing `import GRDB`, add it at the top.

- [ ] **Step 2: Run it**

Run: `make build-tests` then `make test-only FILTER=EchoTests/NarrationChapterPlannerTests`
Expected: PASS (this confirms existing behavior; it is a regression guard, so it passes immediately).

- [ ] **Step 3: Commit**

```bash
git add EchoTests/NarrationChapterPlannerTests.swift
git commit -m "test(narration): guard that a hidden chapter drops from the visible plan"
```

---

### Task 4: PlayerModel narration outline API

Wires the builder to the model: `isNarrationBook`, `narrationOutline`, and the toggle.

**Files:**
- Modify: `EchoCore/ViewModels/PlayerModel+Narration.swift` (add to the `extension PlayerModel`, inside `#if os(iOS)`)
- Test: `EchoTests/NarrationOutlineModelTests.swift` (create) — covers the pure `isNarrationBook` rule via a small extracted helper.

**Interfaces:**
- Consumes: `NarrationOutlineBuilder.build`, `EPubBlockDAO.allBlocks(for:)`, `AlignmentService.hideChapter`/`unhideChapter`, `NarrationCache.directory()`, `NarrationFileNaming.chapterFileName`.
- Produces:
  - `PlayerModel.isNarrationBook: Bool`
  - `PlayerModel.narrationOutline: [NarrationOutlineChapter]` (rebuilt on demand via `refreshNarrationOutline()`)
  - `PlayerModel.toggleNarrationChapterExcluded(chapterIndex: Int)`
  - `enum NarrationBookClassifier { static func isNarrationBook(hasEPUB: Bool, trackPaths: [String], narrationCachePath: String) -> Bool }`

- [ ] **Step 1: Write the failing test (pure classifier)**

Create `EchoTests/NarrationOutlineModelTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct NarrationOutlineModelTests {
    @Test func classifierFlagsAudiolessAndNarrationCacheBooks() {
        let cache = "/Library/App/Narration"
        // Audio-less EPUB (no tracks yet) → narration book.
        #expect(
            NarrationBookClassifier.isNarrationBook(
                hasEPUB: true, trackPaths: [], narrationCachePath: cache) == true)
        // Tracks that are narration-cache files → still a narration book.
        #expect(
            NarrationBookClassifier.isNarrationBook(
                hasEPUB: true, trackPaths: ["\(cache)/syn-bk-ch0.m4a"],
                narrationCachePath: cache) == true)
        // Imported audiobook (tracks outside the narration cache) → NOT.
        #expect(
            NarrationBookClassifier.isNarrationBook(
                hasEPUB: true, trackPaths: ["/Users/me/Books/ch1.mp3"],
                narrationCachePath: cache) == false)
        // No EPUB → NOT.
        #expect(
            NarrationBookClassifier.isNarrationBook(
                hasEPUB: false, trackPaths: [], narrationCachePath: cache) == false)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `make build-tests` then `make test-only FILTER=EchoTests/NarrationOutlineModelTests`
Expected: FAIL — `NarrationBookClassifier` not found.

- [ ] **Step 3: Implement the classifier + model API**

In `EchoCore/ViewModels/PlayerModel+Narration.swift`, inside the `#if os(iOS)` block, ABOVE `extension PlayerModel {` add the pure classifier:

```swift
/// Pure rule for "this book is narrated on-device" (vs an imported audiobook):
/// it has EPUB text, and any tracks present are files in the narration cache.
/// Stable before render (no tracks) and during render (narration-cache tracks).
enum NarrationBookClassifier {
    static func isNarrationBook(
        hasEPUB: Bool, trackPaths: [String], narrationCachePath: String
    ) -> Bool {
        guard hasEPUB else { return false }
        return trackPaths.allSatisfy { $0.hasPrefix(narrationCachePath) }
    }
}
```

Then inside `extension PlayerModel { … }` add:

```swift
        /// True when the playlist should show the narration chapter outline.
        var isNarrationBook: Bool {
            NarrationBookClassifier.isNarrationBook(
                hasEPUB: hasEPUB,
                trackPaths: state.tracks.map { $0.url.path },
                narrationCachePath: Self.narrationCacheDirectory().path)
        }

        /// Rebuilds `narrationOutline` from the book's EPUB blocks + which chapter
        /// files exist. Cheap; call on book load, after a chapter renders, and
        /// after a toggle.
        func refreshNarrationOutline() {
            guard let audiobookID = folderURL?.absoluteString,
                let db = databaseService?.writer
            else {
                state.narrationOutline = []
                return
            }
            let blocks = (try? EPubBlockDAO(db: db).allBlocks(for: audiobookID)) ?? []
            let cacheDir = Self.narrationCacheDirectory()
            let voiceID = VoiceID(settingsManager?.narrationVoiceID ?? VoiceCatalog.default.id.rawValue)
            state.narrationOutline = NarrationOutlineBuilder.build(allBlocks: blocks) { idx in
                let url = cacheDir.appendingPathComponent(
                    NarrationFileNaming.chapterFileName(
                        audiobookID: audiobookID, chapterIndex: idx, voice: voiceID))
                return FileManager.default.fileExists(atPath: url.path)
            }
        }

        /// Convenience accessor for the view.
        var narrationOutline: [NarrationOutlineChapter] { state.narrationOutline }

        /// Toggles whether a chapter is narrated. Excluding hides all its blocks
        /// (dropped from `NarrationChapterPlanner.plan(from: visibleBlocks)` → never
        /// synthesized and never queued); including unhides them. The rendered file,
        /// if any, is left on disk so re-including is instant.
        func toggleNarrationChapterExcluded(chapterIndex: Int) {
            guard let audiobookID = folderURL?.absoluteString,
                let db = databaseService?.writer
            else { return }
            let currentlyExcluded =
                state.narrationOutline.first { $0.chapterIndex == chapterIndex }?.isExcluded ?? false
            let service = AlignmentService(db: db, audiobookID: audiobookID)
            do {
                if currentlyExcluded {
                    try service.unhideChapter(chapterIndex: chapterIndex)
                } else {
                    try service.hideChapter(chapterIndex: chapterIndex, reason: "Excluded from narration")
                }
            } catch {
                return
            }
            // Drop a newly-excluded chapter from the live queue unless it is the one
            // currently playing (let that finish; future renders already exclude it).
            if !currentlyExcluded {
                let fileName = NarrationFileNaming.chapterFileName(
                    audiobookID: audiobookID, chapterIndex: chapterIndex,
                    voice: VoiceID(settingsManager?.narrationVoiceID ?? VoiceCatalog.default.id.rawValue))
                if let removeAt = state.tracks.firstIndex(where: {
                    $0.url.lastPathComponent == fileName
                }), removeAt != state.currentIndex {
                    state.tracks.remove(at: removeAt)
                    if removeAt < state.currentIndex { state.currentIndex -= 1 }
                }
            }
            refreshNarrationOutline()
        }
```

In `EchoCore/ViewModels/PlayerState.swift` (or wherever `state` lives — the `@Observable` state object), add the stored property:

```swift
    var narrationOutline: [NarrationOutlineChapter] = []
```

(If `state` is `PlayerState`, find it via `grep -n "var tracks" EchoCore/**/PlayerState*.swift` and add the line beside `tracks`.)

- [ ] **Step 4: Run to verify it passes**

Run: `make build-tests` then `make test-only FILTER=EchoTests/NarrationOutlineModelTests`
Expected: PASS.

- [ ] **Step 5: Refresh the outline on book load + after each chapter renders**

In `EchoCore/ViewModels/PlayerModel+Narration.swift`, in `startNarrationPlayback`, after `let plan = NarrationChapterPlanner.plan(from: blocks)` succeeds (and is non-empty), add `self.refreshNarrationOutline()`. Also call `self.refreshNarrationOutline()` right after each successful `service.renderChapter(...)` in BOTH render loops (so `isRendered` flips live). Find the call sites:

Run: `grep -n "service.renderChapter" EchoCore/ViewModels/PlayerModel+Narration.swift`
After each `try await service.renderChapter(...)` (and its trailing cancellation/book-switch guards), add:

```swift
                            self.refreshNarrationOutline()
```

Also call `refreshNarrationOutline()` once where the book first loads an EPUB so the outline is present before Play. Find the EPUB-load completion (the same place `startNarrationPlayback` or `loadFolder` finishes the audio-less import) and call it there; if unsure, calling it at the top of `startNarrationPlayback` (after `audiobookID`/`db` are unwrapped) is sufficient for v1.

- [ ] **Step 6: Build to verify it compiles**

Run: `make build-tests`
Expected: `** TEST BUILD SUCCEEDED **`.

- [ ] **Step 7: Commit**

```bash
git add EchoCore/ViewModels/PlayerModel+Narration.swift EchoTests/NarrationOutlineModelTests.swift EchoCore/ViewModels/PlayerState.swift
git commit -m "feat(narration): PlayerModel chapter-outline API + tap-to-exclude wiring"
```

---

### Task 5: PlaylistView narration outline section

Renders the outline for narration books: tap a row to toggle exclusion (greyed when excluded), play affordance for rendered chapters.

**Files:**
- Modify: `EchoCore/Views/PlaylistView.swift`

**Interfaces:**
- Consumes: `model.isNarrationBook`, `model.narrationOutline`, `model.toggleNarrationChapterExcluded(chapterIndex:)`, `model.refreshNarrationOutline()`, and (for play) the existing per-chapter seek used by narration playback.

- [ ] **Step 1: Add the outline section, gated on `isNarrationBook`**

In `PlaylistView.swift`, in the main list `body` where rows render (near the `if cachedPlaylistRows.isEmpty` branch, ~line 305), add a branch BEFORE the existing chapter/track rows:

```swift
                if model.isNarrationBook {
                    Section(header: Text("Chapters")) {
                        ForEach(model.narrationOutline) { chapter in
                            narrationOutlineRow(chapter)
                        }
                    }
                } else if cachedPlaylistRows.isEmpty {
                    // …existing empty branch…
```

(Keep the existing non-narration branches in the `else`.)

- [ ] **Step 2: Add the row view**

Add a private method to `PlaylistView` (near `chapterRowContent`, ~line 530):

```swift
    @ViewBuilder
    private func narrationOutlineRow(_ chapter: NarrationOutlineChapter) -> some View {
        HStack {
            Button {
                model.toggleNarrationChapterExcluded(chapterIndex: chapter.chapterIndex)
                Haptic.play(.rigid)
            } label: {
                HStack {
                    Image(systemName: chapter.isExcluded ? "speaker.slash" : "checkmark.circle.fill")
                        .foregroundStyle(chapter.isExcluded ? Color.secondary : Color.accentColor)
                        .frame(width: 22)
                    Text(chapter.title)
                        .foregroundStyle(chapter.isExcluded ? .secondary : .primary)
                    Spacer()
                    if !chapter.isRendered && !chapter.isExcluded {
                        Text("Pending")
                            .customFont(.caption, appFont: model.resolvedAppFont)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(chapter.title))
            .accessibilityValue(
                Text(chapter.isExcluded ? String(localized: "Excluded") : String(localized: "Included")))
            .accessibilityHint(Text("Double tap to include or exclude this chapter from narration"))
        }
        .opacity(chapter.isExcluded ? 0.55 : 1.0)
    }
```

(YAGNI: a per-chapter play button is deferred — playback still starts via the main Play button and advances through included chapters. The row's job here is the outline + exclude toggle the user asked for.)

- [ ] **Step 3: Refresh the outline when the sheet appears**

Where `PlaylistView` has its `.task`/`.onAppear` (near the `rebuildToken` `.task`, ~line 396), add:

```swift
        .onAppear { if model.isNarrationBook { model.refreshNarrationOutline() } }
```

- [ ] **Step 4: Build to verify it compiles**

Run: `make build-tests`
Expected: `** TEST BUILD SUCCEEDED **`.

- [ ] **Step 5: Manual verification (simulator or device)**

Open an audio-less narration EPUB → open the playlist sheet → confirm the full chapter outline appears before playback, tapping a chapter greys it + shows the speaker-slash, starting narration skips greyed chapters, and re-tapping re-includes. (SwiftUI view rendering is not unit-tested; the model logic it calls is covered by Tasks 2 & 4.)

- [ ] **Step 6: Commit**

```bash
git add EchoCore/Views/PlaylistView.swift
git commit -m "feat(narration): show EPUB chapter outline + tap-to-exclude on the playlist"
```

---

## Self-Review

**Spec coverage:**
- Outline source (`plan(from: allBlocks)`) → Task 2. ✓
- Exclusion via `is_hidden` + `unhideChapter` → Tasks 1, 4. ✓
- Never-render / never-queue excluded chapters → Task 3 (planner guard) + Task 4 (toggle hides) + live-queue removal in Task 4. ✓
- Keep already-rendered files on disk → Task 4 toggle never deletes files. ✓
- Stable numbering + heading/"Chapter N" titles → Task 2. ✓
- UI on the playlist page, greyed when excluded → Task 5. ✓
- Edge case "currently playing excluded chapter" → Task 4 leaves the playing track. ✓ ("exclude-all → No text to narrate" already handled by existing `plan.isEmpty` guard in `startNarrationPlayback`.)

**Placeholder scan:** none — every code step shows complete code. The one "find the exact line" instruction (PlayerState location, renderChapter call sites) is a grep with a fallback, not a placeholder.

**Type consistency:** `NarrationOutlineChapter` fields (`chapterIndex`, `displayNumber`, `title`, `isExcluded`, `isRendered`) are identical across Tasks 2, 4, 5. `unhideChapter(chapterIndex:audiobookID:)` (DAO) and `unhideChapter(chapterIndex:)` (service) match Task 1 → Task 4 usage. `NarrationBookClassifier.isNarrationBook(hasEPUB:trackPaths:narrationCachePath:)` matches Task 4 test and impl.

## Follow-ups (not in this plan)
- Reconcile render-path track titles (`plan(from: visibleBlocks)` numbering) with the outline's stable numbering.
- Resume-anchored play-queue reset (perf review finding #5) — far less visible once the outline ships.
- Optional per-chapter play button on outline rows.
