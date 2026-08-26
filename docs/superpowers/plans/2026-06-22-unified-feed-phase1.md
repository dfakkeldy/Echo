# Unified Feed — Phase 1 (Collapsible Reader Feed, iOS) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the existing iOS EPUB reader feed into a default-collapsed table-of-contents that expands one audio chapter at a time (accordion), auto-expands the playing chapter, and shows honest "has audio / text-only" styling on each collapsed chapter row.

**Architecture:** Evolve `ReaderFeedCollectionView` (UIKit `UICollectionViewDiffableDataSource<String,String>`) and `ReaderFeedViewModel` (`@Observable`). The view model groups its existing per-chapter `ReaderCardSection`s into one collapsible **chapter group** per audio chapter, owns a single `openChapterKey` accordion state, and publishes a derived `displaySections` array (collapsed = one header-only row per chapter; expanded = that chapter's full content). Collapse is a snapshot diff — no new collection-view engine. A dead `.chapterHeader`/`ChapterDividerCell` path is resurrected as the collapsed-TOC row and tap target. Pure logic (accordion math, section→chapter-key mapping, display-section building, batch has-audio) is extracted and unit-tested; the cell/coordinator wiring is build-verified.

**Tech Stack:** Swift 6, SwiftUI + UIKit bridging (`UIViewRepresentable`), GRDB, Swift Testing (`@Test`/`#expect`), `DatabaseService(inMemory:)`.

## Global Constraints

- **License header:** every new `.swift` file starts with `// SPDX-License-Identifier: GPL-3.0-or-later` on **line 1**. A SwiftFormat PostToolUse hook reflows imports on edit and can displace the SPDX header below an `import` — after editing, verify SPDX is still line 1 (a blank line after it detaches it from the import block).
- **Branch:** `feature/unified-feed-phase1`, cut from `origin/nightly` (PR #147 with the Phase-0 `ChapterAudioStatusResolver` is **already merged to nightly** — verified: merge commit `225e3eb`, resolver commit `cfe1d94` contained in `origin/nightly`). PRs target **`nightly`**, never `main`.
- **Scope is iOS only.** `ReaderFeedViewModel` / `ReaderFeedCollectionView` / `ReaderTab` import UIKit and are not in the macOS target. macOS parity is a later phase (spec §12). New **pure** types must stay UIKit-free so macOS can reuse them later: `FeedAccordion` and the `ChapterAudioStatusResolver` batch addition go in `Shared/`; `ReaderFeedDisplayBuilder` + `ReaderChapterGroup` go in `EchoCore/Models/` (already UIKit-free, alongside `ReaderCardItem`).
- **Out of scope this phase (do not build):** word-tap-to-seek (its own later plan — `UILabel` can't hit-test characters); the long-press off-switch / grey-out / `OffState` resolver (Phase 2); filters and session scope (Phase 3); bookmarks/cards/memos as feed items (Phases 2/4). **Keep `EPUBTOCSheet` exactly as-is** — the inline collapsible feed coexists with the sheet this phase.
- **Build discipline (16 GB machine):** never run two `xcodebuild` invocations concurrently. The overnight `~/Developer/echo-overnight/redo-resume.sh` (NarrationHarness) holds the **exclusive** build slot — confirm it is idle/paused before any `make build-tests`. Run all builds in the **foreground** with a long timeout (`timeout: 600000`); a subagent that backgrounds a build yields unresumably. `make build-tests` and `make test-only` already pass `CODE_SIGNING_ALLOWED=NO` (Makefile `CODESIGN_OFF`); the sim destination is `iPhone 17`.
- **No schema change** in this phase (spec §10). Reads only existing tables: `epub_block`, `alignment_anchor`, `chapter`, `timeline_item`.

---

## File Structure

**New files**

- `Shared/Services/ChapterAudioStatusResolver.swift` *(modify — add batch method to the Phase-0 type)*
- `Shared/FeedAccordion.swift` *(create — pure accordion state math; no UIKit/DB)*
- `EchoCore/Models/ReaderFeedDisplayBuilder.swift` *(create — `ReaderChapterGroup` + pure grouping/display-section building)*
- `EchoTests/ChapterAudioStatusResolverTests.swift` *(modify — add batch test)*
- `EchoTests/FeedAccordionTests.swift` *(create)*
- `EchoTests/ReaderFeedDisplayBuilderTests.swift` *(create)*
- `EchoTests/ReaderFeedViewModelAccordionTests.swift` *(create)*

**Modified files**

- `EchoCore/ViewModels/ReaderFeedViewModel.swift` — build chapter groups in `reload()`, own `openChapterKey`, publish `displaySections` + `chapterHasAudio`, add `toggleChapter`, auto-expand in `updateActiveBlock`, `expandChapter(containingBlockID:)`.
- `EchoCore/Views/ReaderFeedCollectionView.swift` — thread `chapterHasAudio` + `openChapterKey` + `onToggleChapter` to the coordinator; configure the chapter-header cell; toggle on header tap; reconfigure header chevrons on accordion change; redesign `ChapterDividerCell`.
- `EchoCore/Views/ReaderTab.swift` — feed the collection from `vm.displaySections`, pass the new params/callback, expand the active chapter on scroll-to-active.

**Responsibility boundaries**

- `FeedAccordion` — *decisions only* (which chapter is open) as pure functions of `Int?`. No data, no UIKit.
- `ReaderFeedDisplayBuilder` — *shape only* (sections → chapter groups → display sections). Pure; depends on `ReaderCardSection`/`ReaderCardItem`/`EPubBlockRecord`, not UIKit.
- `ReaderFeedViewModel` — *state + DB*: holds `openChapterKey`, calls the pure builders, runs DB queries.
- `ReaderFeedCollectionView` — *rendering*: turns `displaySections` + flags into cells; routes taps back to the VM.

---

## Reference: load-bearing facts verified in the code

- `ReaderCardItem` (`EchoCore/Models/ReaderCardItem.swift:13`) already has `case chapterHeader(title: String, chapterIndex: Int)` with `id == "ch-\(chapterIndex)"`, and `case block(EPubBlockRecord)` with `id == "b-\(block.id)"`. `Hashable`/`Sendable` already implemented. **No change needed to this enum.**
- `ReaderCardSection` (`…/ReaderCardItem.swift:5`): `let id`, `let headingStack: [String]`, `let items: [ReaderCardItem]`. `id` format is `"ch\(key)-s\(n)"` for browse, `"search"` for search results. `key` is the audio chapter index (`block.chapterIndex ?? -1`; front matter → `-1`, id `"ch-1-s0"`).
- `reload()` (`ReaderFeedViewModel.swift:94`) builds `parsedSections` in document order; `key` (audio chapter index) and `chapterTitle` (`Self.formatChapterTitle(rawTitle)`, or `"Chapter \(key+1)"`, or `""` for front matter) are in scope at `…:151`–`…:224`. **Capture `titlesByKey[key] = chapterTitle` here.**
- Diffable plumbing: `makeDataSource` (`ReaderFeedCollectionView.swift:174`), `applySnapshot` appends `section.items.map(\.id)` per `section.id` (`…:333`), `cell(for:)` resolves via `card(for:)` and switches on the `ReaderCardItem` (`…:247`, `.chapterHeader` at `…:252`), `didSelectItemAt` currently handles only `.block` (`…:581`), sticky title reads `card(for:)`/`headingStack` (`…:504`), `ChapterDividerCell` (`…:605`).
- `ReaderTab.feedCollectionView` passes `sections: vm.sections` + callbacks (`ReaderTab.swift:87`); `EPUBTOCSheet` consumes `vm.sections` (`…:268`) and the chapter-theme picker consumes `vm.sections` (`…:314`) — **leave `vm.sections` as the full list; add `vm.displaySections` for the collection.**
- Phase-0 honest has-audio: `ChapterAudioStatusResolver.hasAudio(audiobookID:chapterIndex:)` (`Shared/Services/ChapterAudioStatusResolver.swift:18`) over the chapter's whole block range; backed by `AlignmentAnchorDAO.hasAnchor(for:anyOf:)` (`Shared/Database/DAOs/AlignmentAnchorDAO.swift:81`) and `EPubBlockDAO.blocks(for:chapterIndex:)` (`Shared/Database/DAOs/EPubBlockDAO.swift:64`).
- Test conventions: Swift Testing `@Test`/`#expect`, `@testable import Echo`, `DatabaseService(inMemory: ())` then `db.writer` / `db.write { db in … }` (see `EchoTests/ChapterAudioStatusResolverTests.swift`). `EPubBlockRecord` has **no custom init** → use the synthesized memberwise initializer for fixtures.

---

## Task 1: Batch has-audio query (`chaptersWithAudio`)

Building one chapter group per chapter means N has-audio checks per `reload()`. Do it in a single JOIN instead of N×2 queries. Extend the Phase-0 `ChapterAudioStatusResolver` (keep `hasAudio(…)` for spot checks).

**Files:**
- Modify: `Shared/Services/ChapterAudioStatusResolver.swift`
- Test: `EchoTests/ChapterAudioStatusResolverTests.swift`

**Interfaces:**
- Produces: `func chaptersWithAudio(audiobookID: String) throws -> Set<Int>` — the set of `epub_block.chapter_index` values (non-null) that have **any** `alignment_anchor`.

- [ ] **Step 1: Write the failing test**

Append to `EchoTests/ChapterAudioStatusResolverTests.swift` (reuses the existing `seed()` / `insertAnchor(_:block:)` helpers in that file):

```swift
    @Test func chaptersWithAudioReturnsOnlyChaptersHavingAnchors() throws {
        let db = try seed()
        // Anchor on the CONTENT block of chapter 0 only (the honesty case).
        try insertAnchor(db, block: "ch0-para")
        let resolver = ChapterAudioStatusResolver(db: db.writer)
        #expect(try resolver.chaptersWithAudio(audiobookID: "book-1") == Set([0]))
    }

    @Test func chaptersWithAudioEmptyWhenNoAnchors() throws {
        let db = try seed()
        let resolver = ChapterAudioStatusResolver(db: db.writer)
        #expect(try resolver.chaptersWithAudio(audiobookID: "book-1").isEmpty)
    }
```

- [ ] **Step 2: Run test to verify it fails**

Confirm the overnight build slot is free, then:

Run: `make build-tests && make test-only FILTER=EchoTests/ChapterAudioStatusResolverTests`
Expected: FAIL — `value of type 'ChapterAudioStatusResolver' has no member 'chaptersWithAudio'`.

- [ ] **Step 3: Write minimal implementation**

Add to `ChapterAudioStatusResolver` in `Shared/Services/ChapterAudioStatusResolver.swift` (after `hasAudio(…)`):

```swift
    /// The set of chapter indices (for `audiobookID`) that have at least one
    /// alignment anchor anywhere in their block range. One query for the whole
    /// book — the feed needs every chapter's status on each reload, so N per-
    /// chapter lookups would be wasteful. Front-matter blocks (null
    /// `chapter_index`) are excluded; the feed groups them under key -1 which by
    /// definition has no audio in practice.
    func chaptersWithAudio(audiobookID: String) throws -> Set<Int> {
        try db.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT eb.chapter_index AS chapter_index
                    FROM epub_block eb
                    JOIN alignment_anchor aa ON aa.epub_block_id = eb.id
                    WHERE eb.audiobook_id = ? AND eb.chapter_index IS NOT NULL
                    """,
                arguments: [audiobookID])
            var result: Set<Int> = []
            for row in rows {
                if let idx: Int = row["chapter_index"] { result.insert(idx) }
            }
            return result
        }
    }
```

Ensure `import GRDB` is present (it already is in this file).

- [ ] **Step 4: Run test to verify it passes**

Run: `make build-tests && make test-only FILTER=EchoTests/ChapterAudioStatusResolverTests`
Expected: PASS (all 5 tests in the suite — 3 pre-existing + 2 new).

- [ ] **Step 5: Commit**

```bash
git add Shared/Services/ChapterAudioStatusResolver.swift EchoTests/ChapterAudioStatusResolverTests.swift
git commit -m "feat(feed): add ChapterAudioStatusResolver.chaptersWithAudio batch query"
```

---

## Task 2: Accordion state math (`FeedAccordion`)

Pure decisions about which single chapter is open. No data, no UIKit — trivially testable and macOS-portable.

**Files:**
- Create: `Shared/FeedAccordion.swift`
- Test: `EchoTests/FeedAccordionTests.swift`

**Interfaces:**
- Produces:
  - `static func toggled(current: Int?, tapped: Int) -> Int?` — one-at-a-time accordion: open the tapped chapter, or close it if it is already the open one.
  - `static func autoExpand(current openKey: Int?, playingChapterKey: Int?, lastPlayingChapterKey: Int?) -> Int?` — when the **playing chapter changes** to a non-nil chapter, force it open; otherwise leave the user's choice untouched.

- [ ] **Step 1: Write the failing test**

Create `EchoTests/FeedAccordionTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

struct FeedAccordionTests {
    // MARK: toggled

    @Test func tappingClosedChapterOpensIt() {
        #expect(FeedAccordion.toggled(current: nil, tapped: 3) == 3)
    }

    @Test func tappingOpenChapterClosesIt() {
        #expect(FeedAccordion.toggled(current: 3, tapped: 3) == nil)
    }

    @Test func tappingDifferentChapterSwitchesOpenOne() {
        #expect(FeedAccordion.toggled(current: 3, tapped: 5) == 5)
    }

    // MARK: autoExpand

    @Test func autoExpandOpensNewlyPlayingChapter() {
        // Playing chapter went 2 -> 3; force chapter 3 open even though the user
        // had chapter 1 open.
        #expect(
            FeedAccordion.autoExpand(current: 1, playingChapterKey: 3, lastPlayingChapterKey: 2) == 3
        )
    }

    @Test func autoExpandLeavesUserChoiceWhenPlayingChapterUnchanged() {
        // Same playing chapter as last tick: respect a manual collapse/open.
        #expect(
            FeedAccordion.autoExpand(current: nil, playingChapterKey: 3, lastPlayingChapterKey: 3)
                == nil
        )
    }

    @Test func autoExpandIgnoresNilPlayingChapter() {
        #expect(
            FeedAccordion.autoExpand(current: 1, playingChapterKey: nil, lastPlayingChapterKey: 2)
                == 1
        )
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make build-tests && make test-only FILTER=EchoTests/FeedAccordionTests`
Expected: FAIL — `cannot find 'FeedAccordion' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `Shared/FeedAccordion.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Pure accordion-state decisions for the unified feed: at most one audio
/// chapter is expanded at a time. Keyed by audio chapter index (`Int`), with
/// `nil` meaning "all collapsed". No UIKit / no DB so iOS and a future macOS
/// feed can share it.
enum FeedAccordion {
    /// Result of tapping a chapter header: open `tapped`, or collapse it when it
    /// is already the open chapter (so a second tap closes).
    static func toggled(current: Int?, tapped: Int) -> Int? {
        current == tapped ? nil : tapped
    }

    /// Playback-driven expansion. When the chapter being played changes to a new
    /// non-nil chapter, force that chapter open (auto-collapsing whatever was
    /// open). When the playing chapter has not changed since the last tick, the
    /// user's manual choice (`current`) is preserved so a deliberate collapse
    /// while staying in the same chapter sticks.
    static func autoExpand(current openKey: Int?, playingChapterKey: Int?, lastPlayingChapterKey: Int?)
        -> Int?
    {
        guard let playingChapterKey, playingChapterKey != lastPlayingChapterKey else {
            return openKey
        }
        return playingChapterKey
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `make build-tests && make test-only FILTER=EchoTests/FeedAccordionTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Shared/FeedAccordion.swift EchoTests/FeedAccordionTests.swift
git commit -m "feat(feed): add FeedAccordion pure accordion-state math"
```

---

## Task 3: Chapter grouping + display-section builder (`ReaderFeedDisplayBuilder`)

Group the per-section feed into one collapsible unit per audio chapter, and build the diffable-ready `displaySections` for any accordion state. Pure over `ReaderCardSection`/`ReaderCardItem`.

**Files:**
- Create: `EchoCore/Models/ReaderFeedDisplayBuilder.swift`
- Test: `EchoTests/ReaderFeedDisplayBuilderTests.swift`

**Interfaces:**
- Consumes: `ReaderCardSection` (`id`, `headingStack`, `items`), `ReaderCardItem.chapterHeader(title:chapterIndex:)` / `.block(EPubBlockRecord)`.
- Produces:
  - `struct ReaderChapterGroup: Identifiable, Sendable` with `let chapterKey: Int`, `let title: String`, `let hasAudio: Bool`, `let sections: [ReaderCardSection]`, `var id: Int { chapterKey }`.
  - `enum ReaderFeedDisplayBuilder` with:
    - `static func chapterKey(forSectionID id: String) -> Int?` — parse `"ch{key}-s{n}"` → `key` (handles negative front-matter key `"ch-1-s0"`); `nil` for `"search"` / unparseable.
    - `static func groups(from sections: [ReaderCardSection], titlesByKey: [Int: String], chaptersWithAudio: Set<Int>) -> [ReaderChapterGroup]` — group sections by parsed key, preserving first-seen order; title from `titlesByKey` (fallback `headingStack.first`, then `"Front Matter"` for key<0 / `"Chapter \(key+1)"`); `hasAudio = chaptersWithAudio.contains(key)`.
    - `static func displaySections(groups: [ReaderChapterGroup], openChapterKey: Int?) -> [ReaderCardSection]` — collapsed chapter → one header-only section (the chapter's first sub-section id, items `[.chapterHeader]`); open chapter → all its sub-sections in order with `.chapterHeader` prepended to the first.

- [ ] **Step 1: Write the failing test**

Create `EchoTests/ReaderFeedDisplayBuilderTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

struct ReaderFeedDisplayBuilderTests {
    /// Minimal `EPubBlockRecord` fixture — only the fields the feed reads matter.
    private func block(_ id: String, chapter: Int) -> EPubBlockRecord {
        EPubBlockRecord(
            id: id, audiobookID: "bk", spineHref: "c.xhtml", spineIndex: 0, blockIndex: 0,
            sequenceIndex: 0, blockKind: "paragraph", text: id, htmlContent: nil, cardColor: nil,
            chapterThemeColor: nil, imagePath: nil, chapterIndex: chapter, isHidden: false,
            hiddenReason: nil, wordCount: nil, markers: nil, textFormats: nil, createdAt: nil,
            modifiedAt: nil)
    }

    /// Chapter 0 = two sub-sections; chapter 1 = one sub-section. Front matter -1.
    private func sampleSections() -> [ReaderCardSection] {
        [
            ReaderCardSection(
                id: "ch-1-s0", headingStack: [""], items: [.block(block("fm-1", chapter: -1))]),
            ReaderCardSection(
                id: "ch0-s0", headingStack: ["Chapter 1"],
                items: [.block(block("c0-a", chapter: 0))]),
            ReaderCardSection(
                id: "ch0-s1", headingStack: ["Chapter 1", "1.1"],
                items: [.block(block("c0-b", chapter: 0))]),
            ReaderCardSection(
                id: "ch1-s0", headingStack: ["Chapter 2"],
                items: [.block(block("c1-a", chapter: 1))]),
        ]
    }

    // MARK: chapterKey parsing

    @Test func parsesPositiveAndNegativeChapterKeys() {
        #expect(ReaderFeedDisplayBuilder.chapterKey(forSectionID: "ch0-s0") == 0)
        #expect(ReaderFeedDisplayBuilder.chapterKey(forSectionID: "ch10-s2") == 10)
        #expect(ReaderFeedDisplayBuilder.chapterKey(forSectionID: "ch-1-s0") == -1)
        #expect(ReaderFeedDisplayBuilder.chapterKey(forSectionID: "search") == nil)
        #expect(ReaderFeedDisplayBuilder.chapterKey(forSectionID: "nonsense") == nil)
    }

    // MARK: grouping

    @Test func groupsSectionsByChapterPreservingOrder() {
        let groups = ReaderFeedDisplayBuilder.groups(
            from: sampleSections(),
            titlesByKey: [-1: "", 0: "Chapter 1", 1: "Chapter 2"],
            chaptersWithAudio: [0])
        #expect(groups.map(\.chapterKey) == [-1, 0, 1])
        #expect(groups[0].title == "Front Matter")  // empty title -> fallback
        #expect(groups[1].title == "Chapter 1")
        #expect(groups[1].sections.count == 2)  // ch0 has s0 + s1
        #expect(groups[1].hasAudio == true)
        #expect(groups[2].hasAudio == false)
    }

    // MARK: display sections — collapsed

    @Test func collapsedShowsOneHeaderRowPerChapter() {
        let groups = ReaderFeedDisplayBuilder.groups(
            from: sampleSections(),
            titlesByKey: [-1: "", 0: "Chapter 1", 1: "Chapter 2"],
            chaptersWithAudio: [0])
        let display = ReaderFeedDisplayBuilder.displaySections(
            groups: groups, openChapterKey: nil)
        // One section per chapter, each carrying only its header item.
        #expect(display.count == 3)
        #expect(display.map(\.id) == ["ch-1-s0", "ch0-s0", "ch1-s0"])
        #expect(display.allSatisfy { $0.items.count == 1 })
        // Pin the front-matter header id (key -1 -> "ch--1", double hyphen). The
        // whole reconfigure path interpolates "ch-\(key)" independently; this test
        // guards the two interpolations agreeing.
        #expect(display[0].items.map(\.id) == ["ch--1"])
        #expect(display[1].items.map(\.id) == ["ch-0"])  // header id for chapter 0
    }

    // MARK: display sections — expanded

    @Test func expandedChapterShowsHeaderThenAllItsContent() {
        let groups = ReaderFeedDisplayBuilder.groups(
            from: sampleSections(),
            titlesByKey: [-1: "", 0: "Chapter 1", 1: "Chapter 2"],
            chaptersWithAudio: [0])
        let display = ReaderFeedDisplayBuilder.displaySections(
            groups: groups, openChapterKey: 0)
        // Chapter 0 expands to its two sub-sections; others stay header-only.
        #expect(display.map(\.id) == ["ch-1-s0", "ch0-s0", "ch0-s1", "ch1-s0"])
        // First sub-section of the open chapter: header prepended, then its block.
        #expect(display[1].items.map(\.id) == ["ch-0", "b-c0-a"])
        #expect(display[2].items.map(\.id) == ["b-c0-b"])  // s1: content only, no header
        #expect(display[3].items.map(\.id) == ["ch-1"])  // chapter 1 still collapsed
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make build-tests && make test-only FILTER=EchoTests/ReaderFeedDisplayBuilderTests`
Expected: FAIL — `cannot find 'ReaderFeedDisplayBuilder' in scope`.
(If the `EPubBlockRecord(...)` fixture fails to compile, the synthesized memberwise init signature drifted — copy the current property order from `Shared/Database/EPubBlockRecord.swift` and adjust the fixture; do not add a custom init to the record.)

- [ ] **Step 3: Write minimal implementation**

Create `EchoCore/Models/ReaderFeedDisplayBuilder.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// One audio chapter as a collapsible unit in the unified feed: a header row
/// plus the reader sub-sections (`ch{key}-s{n}`) that belong to it.
struct ReaderChapterGroup: Identifiable, Sendable {
    /// Audio chapter index (`epub_block.chapter_index`); -1 for front matter.
    let chapterKey: Int
    /// Display title for the collapsed header row.
    let title: String
    /// Honest "has aligned audio" flag (from `ChapterAudioStatusResolver`).
    let hasAudio: Bool
    /// The chapter's reader sub-sections, in document order.
    let sections: [ReaderCardSection]

    var id: Int { chapterKey }
}

/// Pure transforms from the per-section feed to the collapsible chapter feed.
/// No UIKit / no DB so a future macOS feed can reuse it.
enum ReaderFeedDisplayBuilder {
    /// Recover the audio chapter key from a section id of the form
    /// `"ch{key}-s{n}"` (e.g. `"ch0-s1"` → 0, `"ch-1-s0"` → -1). Returns `nil`
    /// for non-chapter sections such as `"search"`.
    static func chapterKey(forSectionID id: String) -> Int? {
        guard id.hasPrefix("ch") else { return nil }
        let afterCh = id.dropFirst(2)  // "0-s1" or "-1-s0"
        guard let sRange = afterCh.range(of: "-s") else { return nil }
        return Int(afterCh[afterCh.startIndex..<sRange.lowerBound])
    }

    /// Group sections by chapter key, preserving the order chapters first appear.
    static func groups(
        from sections: [ReaderCardSection], titlesByKey: [Int: String], chaptersWithAudio: Set<Int>
    ) -> [ReaderChapterGroup] {
        var order: [Int] = []
        var byKey: [Int: [ReaderCardSection]] = [:]
        for section in sections {
            guard let key = chapterKey(forSectionID: section.id) else { continue }
            if byKey[key] == nil { order.append(key) }
            byKey[key, default: []].append(section)
        }
        return order.map { key in
            let subsections = byKey[key] ?? []
            let rawTitle = titlesByKey[key] ?? subsections.first?.headingStack.first
            let title = (rawTitle?.isEmpty == false) ? rawTitle! : fallbackTitle(forKey: key)
            return ReaderChapterGroup(
                chapterKey: key, title: title, hasAudio: chaptersWithAudio.contains(key),
                sections: subsections)
        }
    }

    /// Diffable-ready sections for the given accordion state. Collapsed chapters
    /// contribute one header-only row; the open chapter contributes all its
    /// sub-sections with the header prepended to the first.
    static func displaySections(groups: [ReaderChapterGroup], openChapterKey: Int?)
        -> [ReaderCardSection]
    {
        var out: [ReaderCardSection] = []
        for group in groups {
            let header = ReaderCardItem.chapterHeader(
                title: group.title, chapterIndex: group.chapterKey)
            if openChapterKey == group.chapterKey {
                for (i, section) in group.sections.enumerated() {
                    let items = (i == 0) ? [header] + section.items : section.items
                    out.append(
                        ReaderCardSection(
                            id: section.id, headingStack: section.headingStack, items: items))
                }
            } else {
                let first = group.sections.first
                out.append(
                    ReaderCardSection(
                        id: first?.id ?? "ch\(group.chapterKey)-s0",
                        headingStack: first?.headingStack ?? [group.title], items: [header]))
            }
        }
        return out
    }

    private static func fallbackTitle(forKey key: Int) -> String {
        key < 0 ? "Front Matter" : "Chapter \(key + 1)"
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `make build-tests && make test-only FILTER=EchoTests/ReaderFeedDisplayBuilderTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add EchoCore/Models/ReaderFeedDisplayBuilder.swift EchoTests/ReaderFeedDisplayBuilderTests.swift
git commit -m "feat(feed): add ReaderFeedDisplayBuilder chapter grouping + collapse"
```

---

## Task 4: View-model wiring (groups, accordion state, auto-expand)

Make `ReaderFeedViewModel` own the accordion and publish the derived feed. This is where the pure builders meet the database.

**Files:**
- Modify: `EchoCore/ViewModels/ReaderFeedViewModel.swift`
- Test: `EchoTests/ReaderFeedViewModelAccordionTests.swift`

**Interfaces:**
- Consumes: `ChapterAudioStatusResolver.chaptersWithAudio` (Task 1), `ReaderFeedDisplayBuilder.groups`/`displaySections` (Task 3), `FeedAccordion.toggled`/`autoExpand` (Task 2).
- Produces (new `private(set)` / methods on `ReaderFeedViewModel`):
  - `private(set) var displaySections: [ReaderCardSection]` — feed for the collection.
  - `private(set) var chapterHasAudio: [Int: Bool]` — per-chapter styling map.
  - `private(set) var chapterThemeColorByKey: [Int: String]` — per-chapter tonal color so the sticky background resolves over collapsed (header-only) rows.
  - `private(set) var openChapterKey: Int?` — accordion state.
  - `func toggleChapter(_ chapterKey: Int)` — user tap.
  - `func expandChapter(containingBlockID blockID: String)` — ensure a block's chapter is open before scroll-to-active.

- [ ] **Step 1: Write the failing test**

Create `EchoTests/ReaderFeedViewModelAccordionTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import GRDB
import Testing

@testable import Echo

@MainActor
struct ReaderFeedViewModelAccordionTests {
    /// `bk`: chapter 0 = heading + paragraph; chapter 1 = heading + paragraph.
    /// A timeline_item maps the chapter-1 paragraph to t=100 with an anchor, so
    /// chapter 1 "has audio" and is the resolvable active block at t=100.
    private func seed() throws -> DatabaseService {
        let db = try DatabaseService(inMemory: ())
        try db.write { db in
            try db.execute(
                sql: "INSERT INTO audiobook (id, title, duration) VALUES ('bk','T',3600)")
            for (id, idx, kind, seq) in [
                ("c0-h", 0, "heading", 0), ("c0-p", 0, "paragraph", 1),
                ("c1-h", 1, "heading", 2), ("c1-p", 1, "paragraph", 3),
            ] {
                try db.execute(
                    sql: """
                        INSERT INTO epub_block
                          (id, audiobook_id, spine_href, spine_index, block_index, sequence_index, block_kind, chapter_index)
                        VALUES (?, 'bk', 'c.xhtml', ?, ?, ?, ?, ?)
                        """,
                    arguments: [id, idx, seq, seq, kind, idx])
            }
            // Anchor + timeline row on chapter 1's paragraph.
            try db.execute(
                sql: """
                    INSERT INTO alignment_anchor (id, audiobook_id, epub_block_id, audio_time, anchor_kind, source)
                    VALUES ('a1','bk','c1-p',100,'point','autoAlignment')
                    """)
            // `timeline_item.title` is NOT NULL with no default, and `id` is the
            // primary key — both must be supplied or the seed throws.
            try db.execute(
                sql: """
                    INSERT INTO timeline_item (id, audiobook_id, epub_block_id, audio_start_time, item_type, title)
                    VALUES ('ti-c1-p','bk','c1-p',100,'textSegment','Para')
                    """)
        }
        return db
    }

    @Test func reloadStartsCollapsedWithOneRowPerChapter() throws {
        let db = try seed()
        let vm = ReaderFeedViewModel(audiobookID: "bk", db: db.writer)
        vm.reload()
        #expect(vm.openChapterKey == nil)
        // Two chapters -> two header-only display sections.
        #expect(vm.displaySections.count == 2)
        #expect(vm.displaySections.allSatisfy { $0.items.count == 1 })
        #expect(vm.chapterHasAudio[1] == true)
        #expect(vm.chapterHasAudio[0] == false)
    }

    @Test func toggleChapterExpandsThenCollapses() throws {
        let db = try seed()
        let vm = ReaderFeedViewModel(audiobookID: "bk", db: db.writer)
        vm.reload()
        vm.toggleChapter(0)
        #expect(vm.openChapterKey == 0)
        // Chapter 0 now shows header + its two blocks (one sub-section here).
        #expect(vm.displaySections.first(where: { $0.id == "ch0-s0" })?.items.count ?? 0 >= 2)
        vm.toggleChapter(0)
        #expect(vm.openChapterKey == nil)
    }

    @Test func playbackAutoExpandsPlayingChapter() throws {
        let db = try seed()
        let vm = ReaderFeedViewModel(audiobookID: "bk", db: db.writer)
        vm.reload()
        #expect(vm.openChapterKey == nil)
        // Paused at t=100: resolves the active block but must NOT auto-expand
        // (default-collapsed TOC).
        vm.updateActiveBlock(time: 100, currentTrackChapterIndices: nil, isPlaying: false)
        #expect(vm.activeBlockID == "c1-p")
        #expect(vm.openChapterKey == nil)
        // Now actually playing: the playing chapter (1) auto-expands.
        vm.updateActiveBlock(time: 100, currentTrackChapterIndices: nil, isPlaying: true)
        #expect(vm.openChapterKey == 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make build-tests && make test-only FILTER=EchoTests/ReaderFeedViewModelAccordionTests`
Expected: FAIL — `value of type 'ReaderFeedViewModel' has no member 'displaySections'` (and `openChapterKey`, `toggleChapter`, `chapterHasAudio`).

- [ ] **Step 3: Write minimal implementation**

In `EchoCore/ViewModels/ReaderFeedViewModel.swift`:

**(a)** Add stored state near the other `private(set)` feed properties (after `sections` at `…:54`):

```swift
    /// Audio-chapter groups (one collapsible unit per chapter), rebuilt on reload.
    private(set) var chapterGroups: [ReaderChapterGroup] = []
    /// The feed actually rendered by the collection: collapsed = one header row
    /// per chapter; the open chapter expands inline. Derived from
    /// `chapterGroups` + `openChapterKey`; `sections` stays the full list for the
    /// TOC sheet / pickers.
    private(set) var displaySections: [ReaderCardSection] = []
    /// Per-chapter honest has-audio flag for header-row styling.
    private(set) var chapterHasAudio: [Int: Bool] = [:]
    /// Per-chapter denormalized theme color, so the sticky background still
    /// resolves while scrolling collapsed (header-only) rows. Absent key = no
    /// theme (neutral) — which also clears a stale tint from a closed chapter.
    private(set) var chapterThemeColorByKey: [Int: String] = [:]
    /// The single expanded chapter (accordion). `nil` = all collapsed.
    private(set) var openChapterKey: Int?
    /// Chapter of the most recent active block, so auto-expand only fires on a
    /// real chapter transition (not every playback tick).
    private var lastPlayingChapterKey: Int?
```

**(b)** In `reload()`, **search branch** (`…:97`–`…:104`): after building the single `sections = [ReaderCardSection(id: "search", …)]`, reset the accordion so search is a flat list:

```swift
                chapterGroups = []
                chapterHasAudio = [:]
                chapterThemeColorByKey = [:]
                openChapterKey = nil
                displaySections = sections
```

**(c)** In `reload()`, **browse branch**: accumulate titles in the chapter loop. At the top of `for key in sortedKeys {` (`…:151`) the local `chapterTitle` is computed; record it. Add a dictionary declared just before the loop:

```swift
                var titlesByKey: [Int: String] = [:]
```

and inside the loop, right after `chapterTitle` is assigned (after the `if isFrontMatter { … } else { … }` block, around `…:162`):

```swift
                    titlesByKey[key] = chapterTitle
```

**(d)** In `reload()`, **browse branch**, replace the bare `sections = parsedSections` (`…:225`) with grouping + display building:

```swift
                sections = parsedSections
                let withAudio =
                    (try? ChapterAudioStatusResolver(db: db).chaptersWithAudio(
                        audiobookID: audiobookID)) ?? []
                chapterGroups = ReaderFeedDisplayBuilder.groups(
                    from: parsedSections, titlesByKey: titlesByKey, chaptersWithAudio: withAudio)
                chapterHasAudio = Dictionary(
                    chapterGroups.map { ($0.chapterKey, $0.hasAudio) }, uniquingKeysWith: { a, _ in a })
                // Denormalized per-chapter theme color (first themed block wins) so
                // the sticky background resolves over collapsed header rows.
                var themeByKey: [Int: String] = [:]
                for group in chapterGroups {
                    outer: for section in group.sections {
                        for item in section.items {
                            if case .block(let b) = item, let theme = b.chapterThemeColor {
                                themeByKey[group.chapterKey] = theme
                                break outer
                            }
                        }
                    }
                }
                chapterThemeColorByKey = themeByKey
                // Keep the open chapter only if it still exists after the reload.
                if let open = openChapterKey,
                    !chapterGroups.contains(where: { $0.chapterKey == open })
                {
                    openChapterKey = nil
                }
                rebuildDisplaySections()
```

**(e)** Add the rebuild helper + accordion API (place after `reload()`):

```swift
    /// Recompute `displaySections` from the current groups + accordion state.
    private func rebuildDisplaySections() {
        displaySections = ReaderFeedDisplayBuilder.displaySections(
            groups: chapterGroups, openChapterKey: openChapterKey)
    }

    /// User tapped a chapter header: open it (collapsing any other), or collapse
    /// it if it was already open.
    func toggleChapter(_ chapterKey: Int) {
        let next = FeedAccordion.toggled(current: openChapterKey, tapped: chapterKey)
        guard next != openChapterKey else { return }
        openChapterKey = next
        rebuildDisplaySections()
    }

    /// Ensure the chapter that owns `blockID` is expanded (used before a
    /// scroll-to-active jump so the target row exists in the snapshot).
    func expandChapter(containingBlockID blockID: String) {
        guard let key = chapterKey(forBlockID: blockID), key != openChapterKey else { return }
        openChapterKey = key
        rebuildDisplaySections()
    }

    /// Resolve a block's audio chapter key: prefer the timeline-derived index,
    /// else find the block's section and parse its id.
    private func chapterKey(forBlockID blockID: String) -> Int? {
        if let idx = chapterIndexByBlockID[blockID] ?? nil { return idx }
        if let indexPath = cardIndexByBlockID[blockID],
            sections.indices.contains(indexPath.section)
        {
            return ReaderFeedDisplayBuilder.chapterKey(forSectionID: sections[indexPath.section].id)
        }
        return nil
    }
```

**(f)** Add an `isPlaying` parameter to `updateActiveBlock` and wire the gated auto-expand. Change the signature (`…:372`) from `func updateActiveBlock(time: TimeInterval, currentTrackChapterIndices: Set<Int>?)` to add a **defaulted** flag (the default keeps existing callers and the track-scoping tests compiling unchanged):

```swift
    func updateActiveBlock(
        time: TimeInterval, currentTrackChapterIndices: Set<Int>?, isPlaying: Bool = false
    ) {
```

Then, after the existing `activeBlockID` update block (after `…:383`), add the auto-expand — **gated on `isPlaying`**. This is the deterministic rule for "default collapsed = TOC": a freshly-opened or resumed-but-paused book never auto-expands; the chapter opens the moment the user actually plays, and only on a real chapter transition (so a manual collapse within the playing chapter sticks):

```swift
        // Auto-expand the chapter being played — but only WHILE PLAYING (so a
        // fresh/resumed-but-paused book stays a collapsed TOC) and only on a real
        // chapter transition (so a manual collapse within the same chapter sticks).
        if isPlaying {
            let playingChapterKey = foundBlockID.flatMap { chapterIndexByBlockID[$0] ?? nil }
            let nextOpen = FeedAccordion.autoExpand(
                current: openChapterKey, playingChapterKey: playingChapterKey,
                lastPlayingChapterKey: lastPlayingChapterKey)
            lastPlayingChapterKey = playingChapterKey
            if nextOpen != openChapterKey {
                openChapterKey = nextOpen
                rebuildDisplaySections()
            }
        }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `make build-tests && make test-only FILTER=EchoTests/ReaderFeedViewModelAccordionTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Run the regression suites that touch this view model**

Run: `make test-only FILTER=EchoTests/ReaderBreadcrumbTests` then `make test-only FILTER=EchoTests/ReaderActiveBlockTrackScopingTests`
Expected: PASS (no behavior change to `sections`, breadcrumb, or active-block scoping — those still read `sections`/`headingStack`).

- [ ] **Step 6: Commit**

```bash
git add EchoCore/ViewModels/ReaderFeedViewModel.swift EchoTests/ReaderFeedViewModelAccordionTests.swift
git commit -m "feat(feed): ReaderFeedViewModel owns accordion state + display sections"
```

---

## Task 5: Collection-view wiring + chapter-header cell

Render `displaySections`, style/タtoggle the header rows, and keep chevrons correct across accordion changes. UIKit cell + coordinator + `UIViewRepresentable` + the SwiftUI host. Verified by build + the pure tests from Tasks 1–4 (the logic was already tested; this task is wiring).

**Files:**
- Modify: `EchoCore/Views/ReaderFeedCollectionView.swift`
- Modify: `EchoCore/Views/ReaderTab.swift`

**Interfaces:**
- Consumes: `vm.displaySections`, `vm.chapterHasAudio`, `vm.openChapterKey`, `vm.toggleChapter(_:)`, `vm.expandChapter(containingBlockID:)`.

- [ ] **Step 1: Redesign `ChapterDividerCell`**

Replace the `ChapterDividerCell` class at the bottom of `ReaderFeedCollectionView.swift` (`…:605`) with a TOC-style row: leading chevron, title, trailing audio indicator, accessible as a button.

```swift
// MARK: - Chapter Header Cell (collapsed-TOC row)

private final class ChapterDividerCell: UICollectionViewCell {
    static let reuseIdentifier = "ChapterDividerCell"

    private let chevron = UIImageView()
    private let titleLabel = UILabel()
    private let audioIcon = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)

        chevron.contentMode = .scaleAspectFit
        chevron.tintColor = .tertiaryLabel
        chevron.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.textColor = .label
        titleLabel.numberOfLines = 2
        titleLabel.adjustsFontForContentSizeCategory = true

        audioIcon.contentMode = .scaleAspectFit
        audioIcon.setContentHuggingPriority(.required, for: .horizontal)

        let stack = UIStackView(arrangedSubviews: [chevron, titleLabel, audioIcon])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            chevron.widthAnchor.constraint(equalToConstant: 14),
            audioIcon.widthAnchor.constraint(equalToConstant: 18),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 4),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -12),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    func configure(title: String, hasAudio: Bool, isExpanded: Bool) {
        titleLabel.text = title
        chevron.image = UIImage(systemName: isExpanded ? "chevron.down" : "chevron.right")
        if hasAudio {
            audioIcon.image = UIImage(systemName: "headphones")
            audioIcon.tintColor = .tintColor
            titleLabel.textColor = .label
        } else {
            audioIcon.image = UIImage(systemName: "text.alignleft")
            audioIcon.tintColor = .tertiaryLabel
            titleLabel.textColor = .secondaryLabel
        }
        accessibilityLabel = title
        accessibilityValue =
            (hasAudio ? "Has audio" : "Text only") + ", " + (isExpanded ? "expanded" : "collapsed")
    }
}
```

- [ ] **Step 2: Thread the new inputs through the `UIViewRepresentable`**

In `struct ReaderFeedCollectionView`, add stored inputs next to `sections` (`…:7`):

```swift
    var chapterHasAudio: [Int: Bool] = [:]
    var chapterThemeColorByKey: [Int: String] = [:]
    var openChapterKey: Int? = nil
    var onToggleChapter: ((Int) -> Void)?
```

In the `Coordinator`, add matching state (near `sections` at `…:206`):

```swift
        var chapterHasAudio: [Int: Bool] = [:]
        var chapterThemeColorByKey: [Int: String] = [:]
        var openChapterKey: Int?
        var onToggleChapter: ((Int) -> Void)?
```

`makeCoordinator()` needs no change (these are set in `updateUIView`). In `updateUIView` (`…:78`), set the new inputs alongside the others (after `…:81`):

```swift
        context.coordinator.onToggleChapter = onToggleChapter
        context.coordinator.chapterHasAudio = chapterHasAudio
        context.coordinator.chapterThemeColorByKey = chapterThemeColorByKey
```

- [ ] **Step 3: Configure the header cell in `cell(for:)`**

In `Coordinator.cell(for:…)`, replace the `.chapterHeader` case (`…:252`–`…:259`) with one that reads the audio/expanded state:

```swift
            case .chapterHeader(let title, let chapterIndex):
                guard
                    let cell = collectionView.dequeueReusableCell(
                        withReuseIdentifier: ChapterDividerCell.reuseIdentifier, for: indexPath
                    ) as? ChapterDividerCell
                else { return UICollectionViewCell() }
                cell.configure(
                    title: title, hasAudio: chapterHasAudio[chapterIndex] ?? false,
                    isExpanded: openChapterKey == chapterIndex)
                return cell
```

- [ ] **Step 4: Toggle on header tap in `didSelectItemAt`**

Replace `collectionView(_:didSelectItemAt:)` (`…:581`–`…:588`) so headers toggle and blocks keep their existing behavior:

```swift
        func collectionView(
            _ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath
        ) {
            guard let itemID = dataSource?.itemIdentifier(for: indexPath),
                let item = card(for: itemID)
            else { return }
            switch item {
            case .chapterHeader(_, let chapterIndex):
                onToggleChapter?(chapterIndex)
            case .block(let block):
                onTapBlock?(block.id)
            }
        }
```

- [ ] **Step 5: Re-apply snapshot on accordion change + keep chevrons correct**

The header item ids (`"ch-{key}"`) are stable, so a diff that only changes section structure won't re-run the cell provider for a header whose chevron must flip. Capture the previous open key and reconfigure the two affected headers in the same snapshot apply.

Change `applySnapshot` (`…:333`) to accept items to reconfigure:

```swift
        func applySnapshot(
            animated: Bool, in collectionView: UICollectionView, reconfiguring: [String] = []
        ) {
            var snapshot = NSDiffableDataSourceSnapshot<String, String>()
            let sectionIDs = sections.map(\.id)
            snapshot.appendSections(sectionIDs)
            for section in sections {
                snapshot.appendItems(section.items.map(\.id), toSection: section.id)
            }
            let present = Set(sections.flatMap { $0.items.map(\.id) })
            let toReconfigure = reconfiguring.filter { present.contains($0) }
            if !toReconfigure.isEmpty { snapshot.reconfigureItems(toReconfigure) }
            dataSource?.apply(snapshot, animatingDifferences: animated)
            Task { @MainActor in
                self.updateTopChapterTitle(collectionView)
            }
        }
```

In `updateUIView`, the `sections` change block (`…:139`–`…:151`) must know whether the open chapter changed. Replace the section-sync block with:

```swift
        let previousOpenKey = context.coordinator.openChapterKey
        let openKeyChanged = openChapterKey != previousOpenKey
        context.coordinator.openChapterKey = openChapterKey

        if sections != context.coordinator.sections {
            let wasEmpty = context.coordinator.sections.isEmpty
            context.coordinator.sections = sections
            let headerReconfigures =
                openKeyChanged
                ? [previousOpenKey, openChapterKey].compactMap { $0.map { "ch-\($0)" } } : []
            context.coordinator.applySnapshot(
                animated: !wasEmpty, in: collectionView, reconfiguring: headerReconfigures)

            if wasEmpty, let firstSection = sections.first,
                let title = firstSection.headingStack.first
            {
                Task { @MainActor in
                    self.topChapterTitle = title
                }
            }
        } else if openKeyChanged {
            // Same section structure but a header chevron must flip (rare; e.g. a
            // chapter with no extra sub-sections).
            context.coordinator.applySnapshot(
                animated: true, in: collectionView,
                reconfiguring: [previousOpenKey, openChapterKey].compactMap { $0.map { "ch-\($0)" } }
            )
        }
```

> Note: `context.coordinator.openChapterKey` must be assigned **before** the `sections` comparison uses `previousOpenKey` — the snippet above captures `previousOpenKey` first, so keep that ordering.

- [ ] **Step 5b: Keep the sticky background correct for collapsed rows**

`updateChapterTitle` (`ReaderFeedCollectionView.swift:504`) derives the screen's tonal background (`topChapterThemeColor`) from the **centered block's** `chapterThemeColor`. Once collapsed sections hold only a `.chapterHeader` (no `.block`), both existing branches miss and the background tint goes stale (e.g. stuck on the last-read chapter's color). Resolve the theme from the new map for header items. Replace the theme-color block at the end of `updateChapterTitle` (`…:558`–`…:577`) with:

```swift
                var resolvedTheme: String? = nil
                if let itemID = dataSource?.itemIdentifier(for: indexPath),
                    let item = card(for: itemID)
                {
                    switch item {
                    case .block(let block):
                        resolvedTheme = block.chapterThemeColor
                    case .chapterHeader(_, let chapterIndex):
                        resolvedTheme = chapterThemeColorByKey[chapterIndex]
                    }
                } else if let firstBlock = section.items.compactMap({ item -> EPubBlockRecord? in
                    if case .block(let b) = item { return b }
                    return nil
                }).first {
                    resolvedTheme = firstBlock.chapterThemeColor
                }
                if topChapterThemeColor.wrappedValue != resolvedTheme {
                    Task { @MainActor in
                        self.topChapterThemeColor.wrappedValue = resolvedTheme
                    }
                }
```

(This also fixes a latent staleness: a collapsed chapter with no theme now correctly clears the tint to neutral instead of inheriting the previous chapter's color.)

- [ ] **Step 6: Feed the collection from `displaySections` in `ReaderTab`**

In `ReaderTab.swift`, `feedCollectionView` (`…:92`), change the `sections:` argument and add the new params/callback:

```swift
            ReaderFeedCollectionView(
                sections: vm.displaySections,
                activeBlockID: bindableVM.activeBlockID,
                activeWord: vm.activeWord,
                isHeaderVisible: $isHeaderVisible,
                autoScrollEnabled: $autoScrollEnabled,
                topPartTitle: $topPartTitle,
                topChapterTitle: $topChapterTitle,
                topSectionTitle: $topSectionTitle,
                topChapterThemeColor: $topChapterThemeColor,
                settings: readerSettings,
                alignmentStatusByBlockID: vm.alignmentStatusByBlockID,
                audioStartTimeByBlockID: vm.audioStartTimeByBlockID,
                chapterHasAudio: vm.chapterHasAudio,
                chapterThemeColorByKey: vm.chapterThemeColorByKey,
                openChapterKey: vm.openChapterKey,
                searchQuery: query,
                pulseBlockID: pulseBlockID,
                forceScrollBlockID: forceScrollBlockID,
                forceScrollTrigger: forceScrollTrigger,
                onToggleChapter: { (chapterKey: Int) -> Void in
                    vm.toggleChapter(chapterKey)
                },
                onTapBlock: { (blockID: String) -> Void in
                    tapBlock(blockID)
                },
                onContextMenu: { (block: EPubBlockRecord) -> UIContextMenuConfiguration? in
                    buildContextMenu(block: block)
                }
            )
```

- [ ] **Step 7: Expand the active chapter before scroll-to-active**

So "scroll to current position" works even if the user collapsed the playing chapter, update the `epubScrollToActiveTrigger` handler in `ReaderTab.swift` (`…:220`):

```swift
        .onChange(of: model.epubScrollToActiveTrigger) { _, _ in
            autoScrollEnabled = true
            if let activeID = viewModel?.activeBlockID {
                viewModel?.expandChapter(containingBlockID: activeID)
                forceScrollBlockID = activeID
                forceScrollTrigger += 1
            }
        }
```

Then pass `isPlaying` to the two `updateActiveBlock` call sites so the playing chapter auto-expands only during playback. Update the `currentPlaybackTime` handler (`ReaderTab.swift:227`):

```swift
        .onChange(of: model.currentPlaybackTime) { _, newPos in
            viewModel?.updateActiveBlock(
                time: newPos, currentTrackChapterIndices: currentTrackChapterIndices,
                isPlaying: model.isPlaying)
        }
```

and the `currentIndex` (track-boundary) handler (`ReaderTab.swift:234`):

```swift
        .onChange(of: model.currentIndex) { _, _ in
            viewModel?.updateActiveBlock(
                time: model.currentPlaybackTime,
                currentTrackChapterIndices: currentTrackChapterIndices,
                isPlaying: model.isPlaying
            )
        }
```

> If product testing later wants the playing chapter to also auto-expand the instant the user *taps a paragraph to play* (rather than on the next tick), that already works: `tapBlock` calls `model.play()`, after which `currentPlaybackTime` ticks arrive with `isPlaying == true`.

- [ ] **Step 8: Build-verify the whole target**

Run: `make build-tests`
Expected: BUILD SUCCEEDED, no errors. (Foreground; long timeout; overnight slot idle.)

- [ ] **Step 9: Run all new + adjacent suites together**

Run: `make test-only FILTER=EchoTests/ChapterAudioStatusResolverTests` ; `make test-only FILTER=EchoTests/FeedAccordionTests` ; `make test-only FILTER=EchoTests/ReaderFeedDisplayBuilderTests` ; `make test-only FILTER=EchoTests/ReaderFeedViewModelAccordionTests`
Expected: all PASS.

- [ ] **Step 10: Commit**

```bash
git add EchoCore/Views/ReaderFeedCollectionView.swift EchoCore/Views/ReaderTab.swift
git commit -m "feat(feed): collapsible chapter rows in the reader feed (accordion + has-audio)"
```

---

## Task 6: Simulator smoke test, parity check, and doc-sync

**Files:**
- (verification only) + `CHANGELOG.md`

- [ ] **Step 1: Launch the reader and verify the collapsed TOC**

Build & run the app on the iOS simulator (foreground). Open a book with an EPUB + audio. Verify:
- The reader opens **collapsed**: one row per audio chapter, each with a chevron and either a `headphones` (has audio) or `text.alignleft` (text only) trailing icon; text-only rows render in secondary color.
- Tapping a chapter row **expands it in place** (chevron → down) and **collapses any previously-open chapter** (accordion).
- Tapping the open chapter's row **collapses it** (chevron → right).
- Pressing play / seeking into a different chapter **auto-expands that chapter** and the karaoke highlight still follows.
- The `EPUBTOCSheet` (list button in the utilities row) still opens and navigates unchanged.

Use the simulator-tester agent or `xcui`/screenshots to capture the collapsed and expanded states as proof. If anything misbehaves, diagnose via source (most likely the snapshot reconfigure ordering in Task 5 Step 5) and re-verify.

- [ ] **Step 2: Cross-platform parity check**

The new pure types live in `Shared/` (`FeedAccordion`, `chaptersWithAudio`) and `EchoCore/Models/` (`ReaderFeedDisplayBuilder`) and must stay UIKit-free. Confirm none import UIKit and that the macOS target still builds is **not required this phase** (macOS reader is untouched), but run the parity reviewer to be safe:

Dispatch the `cross-platform-parity-reviewer` agent on the diff (it checks Shared/EchoCore changes reach or are deliberately gated on every surface). Expected: the reader-feed changes are correctly iOS-only; the Shared additions are platform-agnostic. Address any flagged regression.

- [ ] **Step 3: Doc-sync (CLAUDE.md requirement)**

This phase changes reader-feed behavior (collapsible TOC). Per CLAUDE.md, docs must be offered an update. Add a CHANGELOG entry under the unreleased/nightly section:

```markdown
### Added
- Reader feed is now a collapsible table of contents: tap a chapter to expand it inline (one open at a time); the playing chapter auto-expands. Chapter rows show whether each chapter has aligned audio or is text-only.
```

Then **remind the user** that `ARCHITECTURE.md` (reader feed section) and `ROADMAP.md` (unified-feed phase tracker) may want a line about Phase 1 landing, and offer to update them. (Do not silently rewrite ARCHITECTURE.md — offer the snippet.) Invoke the `doc-sync` skill for the full pass before opening the PR.

- [ ] **Step 4: Commit + open the PR**

```bash
git add CHANGELOG.md
git commit -m "docs(changelog): collapsible reader feed (unified feed Phase 1)"
git push -u origin feature/unified-feed-phase1
gh pr create --base nightly --title "feat(feed): unified feed Phase 1 — collapsible reader feed (iOS)" --body "Implements Phase 1 of the unified-feed initiative (spec §3, §4). Default-collapsed reader feed = TOC; tap a chapter to expand (accordion, one at a time); playing chapter auto-expands; honest has-audio / text-only styling on chapter rows via the Phase-0 ChapterAudioStatusResolver. Keeps EPUBTOCSheet. Word-tap-to-seek and the off-switch are out (later phases)."
```

---

## Self-Review

**1. Spec coverage (Phase 1 scope per spec §3, §4, §12 and the settled forks):**
- Collapsed = TOC (one row per audio chapter): Task 3 `displaySections(openChapterKey: nil)`, Task 5 cell. ✓
- Tap chapter → expand in place: Task 4 `toggleChapter`, Task 5 `didSelectItemAt`. ✓
- Accordion (one at a time, siblings auto-collapse): `FeedAccordion.toggled` (Task 2) + single `openChapterKey`. ✓
- Playing chapter auto-expands: `FeedAccordion.autoExpand` (Task 2) wired in `updateActiveBlock` (Task 4). ✓
- Sticky header for the open chapter: preserved — `displaySections` keeps real `headingStack`s. `updateChapterTitle`'s breadcrumb path is unaffected; its **theme-color** sub-path is updated (Task 5 Step 5b) to resolve from `chapterThemeColorByKey` for collapsed header rows (otherwise the background tint goes stale). ✓
- Has-audio / text-only styling via Phase-0 resolver: Task 1 batch query → `chapterHasAudio` (Task 4) → cell (Task 5). ✓
- Keep `EPUBTOCSheet` this phase: untouched; still reads `vm.sections`. ✓
- Word-tap-to-seek OUT; off-switch OUT: not implemented. ✓

**2. Placeholder scan:** every code step shows the actual code; no "TBD"/"add error handling"/"similar to Task N". The one judgement call deferred to execution is the simulator visual polish (icon/spacing), which is acceptable as a verification step, not a code placeholder. ✓

**3. Type consistency:**
- `chapterKey(forSectionID:)`, `groups(from:titlesByKey:chaptersWithAudio:)`, `displaySections(groups:openChapterKey:)` — names identical across Task 3 definition and Task 4 call sites. ✓
- `FeedAccordion.toggled(current:tapped:)` / `autoExpand(current:playingChapterKey:lastPlayingChapterKey:)` — identical Task 2 ↔ Task 4. ✓
- `chaptersWithAudio(audiobookID:)` — identical Task 1 ↔ Task 4. ✓
- Header item id is `"ch-\(chapterIndex)"` everywhere (`ReaderCardItem.id`, the `reconfiguring` ids in Task 5, the display-builder test assertions). ✓
- `ReaderChapterGroup` fields (`chapterKey`, `title`, `hasAudio`, `sections`) consistent Task 3 ↔ Task 4. ✓

**Known risks carried into execution (each has a verification step):**
- Snapshot apply + `reconfigureItems` ordering (Task 5 Step 5) is the most error-prone wiring — Step 8/9/Task 6 Step 1 verify it. `reconfigureItems` is iOS 15+ and is not used elsewhere in the codebase today, so exercise the collapse→expand chevron flip explicitly on-device.
- "Default collapsed": resolved deterministically — auto-expand is gated on `isPlaying` (Task 4f + Task 5 Step 7), so a fresh or resumed-but-paused book stays a TOC regardless of whether a block covers t=0. The paused-vs-playing behavior is pinned by `playbackAutoExpandsPlayingChapter` (Task 4) and confirmed on-device (Task 6 Step 1).
- Search resets the accordion: exiting search runs `reload()` which sets `openChapterKey = nil` (the book returns to a collapsed TOC after a search). Intended; noted so it isn't mistaken for a bug.
- Front-matter header id is `"ch--1"` (double hyphen) — load-bearing for the reconfigure filter; pinned by a `ReaderFeedDisplayBuilderTests` assertion (Task 3).
- Empty-section vertical padding when collapsed (each header row sits in its own collection section with 8pt top/bottom insets) — acceptable for Phase 1; tighten in a polish pass if it reads too spacious.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-22-unified-feed-phase1.md`. Two execution options:

1. **Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration. (Tell each implementer: builds run in the **foreground** with `timeout: 600000`; confirm the overnight build slot is idle first.)
2. **Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
