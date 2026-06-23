# Unified Feed — Phase 2 (Feed Becomes the Study Surface, iOS) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the unified Read feed the single Study surface. Render bookmarks and Anki flashcards *inline*, threaded into the correct chapter section in document order; replace the per-chapter on/off scattered across two persistence systems with one read-side `OffStateResolver` truth and a long-press context menu that is the *only* place "off" lives (Turn off everywhere + granular Listen / Narrate / Cards); grey out chapters that are off; retire the chronological Study/timeline playlist; and collapse the Read + Study tabs into a single tab, remapping deep links. `.nowPlaying` is left completely untouched.

**Architecture:** Phase 1 already produced (a) `ReaderFeedViewModel.displaySections` / `openChapterKey` / `chapterHasAudio` / `toggleChapter`, (b) the pure `ReaderFeedDisplayBuilder` (sections → `ReaderChapterGroup` → display sections) and `FeedAccordion`, (c) the resurrected `ChapterDividerCell` + `.chapterHeader` cell path, and (d) `ChapterAudioStatusResolver.chaptersWithAudio`. Phase 2 builds *on* those: it extends the `ReaderCardItem` enum with `.bookmark` / `.ankiCard` cases, teaches `ReaderFeedDisplayBuilder` to splice pre-bucketed bookmarks/cards into each chapter's item list, adds a pure **`OffStateResolver`** (`Shared/`, UIKit-free) that reconciles the audio-layer `isEnabled` (the `.echoplaylist.json` sidecar via `PlaylistManifestService`) against the EPUB-layer `is_hidden` (GRDB `epub_block`) into one `ChapterOffState`, adds two new `UICollectionViewCell` subclasses to the existing diffable registry, and adds a long-press `UIMenu` on chapter-header rows that writes the correct flag(s) per heading kind. The chronological `PlaylistView`/`TimelineTab` is retired and `TabSelection.timeline` is deleted, with the `.read` tab relabelled "Read & Study" and all call sites swept.

> **Phase-1 dependency (D7):** Tasks 4 and 5 require `ReaderFeedViewModel.displaySections`/`openChapterKey`/`chapterHasAudio`/`toggleChapter`, `ReaderFeedDisplayBuilder` (grouping entry point), `FeedAccordion`, and a `ChapterDividerCell` with `configure(title:hasAudio:isExpanded:)` to already be landed in the branch. As of the Phase-1 SDD (commits `a5cc1db` / `adea58d`), only the *pure* Phase-1 pieces are committed (`ReaderFeedDisplayBuilder.swift`, `Shared/FeedAccordion.swift`, `ChapterAudioStatusResolver.swift`); the VM accordion wiring and the `ChapterDividerCell` reshape are still in-progress (Task 4 in the Phase-1 plan). **Do not begin Tasks 4 or 5 of this plan until Phase-1 Task 4 (VM wiring) and Task 5 (cell + coordinator update) are merged into the branch.** Tasks 1, 2, and 3 of this plan are independent and can start immediately.

**Tech Stack:** Swift 6, SwiftUI + UIKit bridging (`UIViewRepresentable`), GRDB, Swift Testing (`@Test`/`#expect`), `DatabaseService(inMemory:)`.

## Global Constraints

- **License header:** every new `.swift` file starts with `// SPDX-License-Identifier: GPL-3.0-or-later` on **line 1**. A SwiftFormat PostToolUse hook reflows imports on edit and can displace the SPDX header below an `import` — after editing, verify SPDX is still line 1 (a blank line after it detaches it from the import block).
- **Branch:** `feature/unified-feed-phase2`, cut from `origin/nightly`. Before any edit in a fresh worktree: `git merge-base --is-ancestor origin/nightly HEAD || (git fetch origin nightly && git reset --hard origin/nightly)`. PRs target **`nightly`**, never `main`. (Phase 1 lands first; if Phase 1 is still open at start, branch from the Phase-1 branch instead and note the dependency in the PR — Phase 2 hard-depends on `displaySections`/`ReaderFeedDisplayBuilder`/`FeedAccordion`/`ChapterDividerCell`.)
- **Scope is iOS only.** `ReaderFeedViewModel` / `ReaderFeedCollectionView` / `ReaderTab` import UIKit and are not in the macOS target. macOS parity is a later phase (spec §12). New **pure** types must stay UIKit-free so macOS can reuse them later: `OffStateResolver` and `ChapterOffState` go in `Shared/`; `FeedAccordion` and `ChapterAudioStatusResolver` (Phase-1 pure types) already live in `Shared/` (not `EchoCore/Models/`); the `ReaderCardItem` enum cases and `ReaderFeedDisplayBuilder` splice logic stay in `EchoCore/Models/` (already UIKit-free).
- **Build discipline (16 GB machine):** never run two `xcodebuild` invocations concurrently. The overnight `~/Developer/echo-overnight/redo-resume.sh` (NarrationHarness) holds the **exclusive** build slot — confirm it is idle/paused before any `make build-tests`. Run all builds in the **foreground** with a long timeout (`timeout: 600000`); a subagent that backgrounds a build yields unresumably. `make build-tests` and `make test-only` already pass `CODE_SIGNING_ALLOWED=NO` (Makefile `CODESIGN_OFF`); the sim destination is `iPhone 17`.
- **No schema change** in this phase (spec §10). Reads/writes only existing tables (`epub_block.is_hidden` via `EPubBlockDAO.hideChapter`/`unhideChapter`) and the existing `.echoplaylist.json` sidecar (`PlaylistManifestService`). If a migration ever *were* needed, claim the **next free version number on `origin/nightly`** (highest committed is `Schema_V23`; do **not** hard-code a number) and route it through the schema-migration-reviewer — but Phase 2 needs none.

---

## Open-question defaults (flagged for owner review)

- **§13.3 swipe gesture:** reserved, do **not** build. The long-press menu is the only off control this phase.
- **OffState write atomicity (Trap C):** no cross-system transaction is possible (GRDB + JSON file). **Default chosen:** write GRDB first (`EPubBlockDAO.hideChapter`/`unhideChapter`), then the manifest; if the manifest write throws, the GRDB write stands and the feed still reads correctly (EPUB hidden) — surface no error, log only. Flagged for owner: acceptable for v1?
- **Bookmark / card placement when `mediaTimestamp` can't resolve to a chapter (Trap A/B):** fall back to bucket key `-1` (front matter) so the item is never silently dropped. Flagged for owner.
- **Granular menu for a chapter with no audio:** "Turn off narration" / "Turn off listening" are shown but disabled (greyed) when the chapter has no audio anchors, since there is nothing to turn off. "Turn off cards" and "Turn off everywhere" are always enabled. Flagged for owner.
- **Tab relabel:** `.read` becomes label `"Read & Study"`, icon unchanged (`book.pages`). `.timeline` case deleted. Flagged for owner (naming).

---

## File Structure

**New files**

- `Shared/OffStateResolver.swift` *(create — `ChapterOffState` enum + pure resolver reading both systems; no UIKit)*
- `EchoTests/OffStateResolverTests.swift` *(create)*
- `EchoTests/ReaderCardItemPhase2Tests.swift` *(create — id/equality/hash for the new cases)*
- `EchoTests/ReaderFeedDisplayBuilderPhase2Tests.swift` *(create — bookmark/card splicing into chapter items)*

**Modified files**

- `EchoCore/Models/ReaderCardItem.swift` — add `.bookmark(BookmarkRecord)` + `.ankiCard(Flashcard)`; extend `id`, `==`, `hash(into:)`.
- `EchoCore/Models/ReaderFeedDisplayBuilder.swift` — accept pre-bucketed `[Int: [ReaderCardItem]]` extras and splice them into each chapter group's items in document order.
- `EchoCore/ViewModels/ReaderFeedViewModel.swift` — fetch bookmarks + flashcards in `reload()`, derive each item's chapter bucket, pass extras to the builder, expose `chapterOffState(_:)` + `setChapterOff(...)` via an injected `OffStateResolver`, observe `.timelineItemsIngested`.
- `EchoCore/Views/ReaderFeedCollectionView.swift` — register `BookmarkFeedCell` + `AnkiCardFeedCell`; dispatch `.bookmark`/`.ankiCard` in `cell(for:)`; add a chapter-header `UIMenu` path; thread `offState` to `ChapterDividerCell.configure` for grey-out; add `onChapterHeaderContextMenu`.
- `EchoCore/Views/ReaderTab.swift` — supply `onChapterHeaderContextMenu`; call `vm.setChapterOff(...)`.
- `Shared/TabSelection.swift` — delete `.timeline`; relabel `.read`.
- `EchoCore/Views/RootTabView.swift` — drop `timelinePath` + the `.timeline` switch arm; merge bookmark sheet hosting into `.read`.
- `EchoCore/Views/BottomToolbarView.swift` — collapse the 3-state tab cycle to a 2-state `nowPlaying ↔ read`.
- `EchoCore/Views/NowPlayingTab.swift` — `onShowBookmarks` → `.read`.
- `EchoCore/Services/DeepLinkHandler.swift` — `.study` → `.navigate(.read)`.
- `EchoCore/ViewModels/PlayerModel.swift` — `.navigateToBookmark` arm → `.read`.
- `EchoCore/Views/TimelineTab.swift` — **delete**.
- `EchoCore/Views/PlaylistView.swift` — **delete** the chronological view; lift the `EditBookmarkView` sheet + DailyReview trigger into `RootTabView` (keep `EditBookmarkView` itself if it lives elsewhere; verify).

**Responsibility boundaries**

- `OffStateResolver` — *truth reconciliation only* (read both stores → one `ChapterOffState`; perform the correct write per heading kind). Pure data + file/DB IO; no UIKit.
- `ReaderFeedDisplayBuilder` — *shape only*; now also splices extras. Pure.
- `ReaderCardItem` — *identity only*; new payload cases.
- `ReaderFeedViewModel` — *state + DB + orchestration*: fetches items, buckets them, asks the resolver, drives reload.
- `ReaderFeedCollectionView` — *rendering + menu construction*: cells for the new item types, the off-menu UI.

---

## Reference: load-bearing facts verified in the code

- `ReaderCardItem` (`EchoCore/Models/ReaderCardItem.swift:13`) currently has only `.chapterHeader(title:chapterIndex:)` (id `"ch-\(chapterIndex)"`) and `.block(EPubBlockRecord)` (id `"b-\(block.id)"`). The future hook comment is at line 18. `==`/`hash(into:)` live at lines 31/42.
- `BookmarkRecord` (`Shared/Database/BookmarkRecord.swift`): `id: String`, `audiobookID`, `trackID: String?`, `title`, `mediaTimestamp: TimeInterval`, `note: String?`, `voiceMemoPath`, `imagePath`, `placeName`, `createdAt`. **No `chapterIndex`/`epubBlockID`** — position derives from `mediaTimestamp`.
- `Flashcard` (`Shared/Database/Flashcard.swift`): `id: String`, `audiobookID`, `frontText`, `backText`, `mediaTimestamp: TimeInterval`, `sourceBlockID: String?` (V15, nullable). `sourceBlockID` is the precise anchor; `nil` cards fall back to `mediaTimestamp`.
- `BookmarkDAO.bookmarks(for:) throws -> [BookmarkRecord]` (`Shared/Database/DAOs/BookmarkDAO.swift:8`); `FlashcardDAO.flashcards(for:) throws -> [Flashcard]` (`Shared/Database/DAOs/FlashcardDAO.swift:12`). Both DAOs are `struct X { let db: DatabaseWriter }`.
- `EPubBlockDAO.hideChapter(chapterIndex:audiobookID:reason:)` / `unhideChapter(chapterIndex:audiobookID:)` (`Shared/Database/DAOs/EPubBlockDAO.swift:144`/`:163`) already exist and are correct (bulk set/clear `is_hidden` for a `chapter_index`). `blocks(for:chapterIndex:)` at `:64`.
- Audio-side `isEnabled` lives **only** in `.echoplaylist.json` `ManifestTrack.enabled` (`EchoCore/Models/EchoPlaylistManifest.swift:19`), read via `PlaylistManifestService.read(from:) -> EchoPlaylistManifest?` (`:14`) and written via `PlaylistManifestService.updateEnabledStates(folderURL:states:)` (`:114`). There is **no** per-chapter audio `isEnabled` row in GRDB.
- `TabSelection` (`Shared/TabSelection.swift:4`): `case nowPlaying`, `case read`, `case timeline`; `icon`/`label` switch on all three.
- `DeepLinkHandler` (`EchoCore/Services/DeepLinkHandler.swift`): `case navigate(TabSelection)` (`:13`); `.read → .navigate(.read)` (`:72`); `.study → .navigate(.timeline)` (`:75`).
- Cell dispatch (`EchoCore/Views/ReaderFeedCollectionView.swift`): registry at `:65`–`:72` (`ChapterDividerCell` at `:72`); `card(for:)` `:238`; `cell(for:)` `:247` with `.chapterHeader` at `:252` (calls `cell.configure(with: title)`) and `.block` at `:261`; `onContextMenu: ((EPubBlockRecord) -> UIContextMenuConfiguration?)?` at `:28`/`:192`/`:223`; the context-menu provider at `:593` returns `onContextMenu?(block)`; `ChapterDividerCell` definition at `:605`, `configure(with:)` at `:629`.
- `ReaderTab` (`EchoCore/Views/ReaderTab.swift`): builds `ReaderFeedCollectionView(...)` at `:92`, passes `onContextMenu:` at `:112`.
- Test conventions: Swift Testing `@Test`/`#expect`, `@testable import Echo`, `DatabaseService(inMemory: ())` then `db.writer` / `db.write { db in … }`. `EPubBlockRecord`, `BookmarkRecord`, `Flashcard` have synthesized memberwise inits (no custom init) → build fixtures positionally/by-label.

---

## Task 1: Extend `ReaderCardItem` with `.bookmark` and `.ankiCard`

The diffable data source keys on `ReaderCardItem.id` (a `String`). New cases must produce globally-unique ids that never collide with `"ch-…"` or `"b-…"`. Use `"bm-\(record.id)"` and `"fc-\(flashcard.id)"`.

**Files:**
- Modify: `EchoCore/Models/ReaderCardItem.swift`
- Test: `EchoTests/ReaderCardItemPhase2Tests.swift`

**Interfaces:**
- Produces: `case bookmark(BookmarkRecord)` (id `"bm-\(record.id)"`), `case ankiCard(Flashcard)` (id `"fc-\(flashcard.id)"`); `Hashable`/`Sendable` extended.

- [ ] **Step 1: Write the failing test**

Create `EchoTests/ReaderCardItemPhase2Tests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct ReaderCardItemPhase2Tests {
    private func makeBookmark(id: String) -> BookmarkRecord {
        BookmarkRecord(
            id: id, audiobookID: "book-1", trackID: nil, title: "BM",
            mediaTimestamp: 12.0, note: nil, voiceMemoPath: nil, imagePath: nil,
            isEnabled: true, playlistPosition: nil, pdfViewStateJSON: nil,
            latitude: nil, longitude: nil, placeName: nil,
            createdAt: "2026-06-22T00:00:00Z", modifiedAt: "2026-06-22T00:00:00Z")
    }

    private func makeCard(id: String) -> Flashcard {
        Flashcard(
            id: id, audiobookID: "book-1", frontText: "Q", backText: "A",
            mediaTimestamp: 12.0, endTimestamp: nil, triggerTiming: .manualOnly,
            nextReviewDate: nil, intervalDays: 0, easeFactor: 2.5, repetitions: 0,
            lastReviewedAt: nil, lastGrade: nil, isEnabled: true, deckID: nil,
            tags: nil, mediaJSON: nil, sourceBlockID: nil, playlistPosition: nil,
            createdAt: nil, modifiedAt: nil, stability: nil, difficulty: nil,
            cardType: "normal", clozeIndex: nil)
    }

    @Test func bookmarkIDIsPrefixedAndUnique() {
        let item = ReaderCardItem.bookmark(makeBookmark(id: "abc"))
        #expect(item.id == "bm-abc")
    }

    @Test func ankiCardIDIsPrefixedAndUnique() {
        let item = ReaderCardItem.ankiCard(makeCard(id: "xyz"))
        #expect(item.id == "fc-xyz")
    }

    @Test func newCasesDoNotCollideWithExistingPrefixes() {
        let ids = Set([
            ReaderCardItem.chapterHeader(title: "T", chapterIndex: 1).id,
            ReaderCardItem.bookmark(makeBookmark(id: "1")).id,
            ReaderCardItem.ankiCard(makeCard(id: "1")).id,
        ])
        #expect(ids.count == 3)
    }

    @Test func equalityAndHashDistinguishCases() {
        let a = ReaderCardItem.bookmark(makeBookmark(id: "1"))
        let b = ReaderCardItem.bookmark(makeBookmark(id: "1"))
        let c = ReaderCardItem.ankiCard(makeCard(id: "1"))
        #expect(a == b)
        #expect(a != c)
        #expect(a.hashValue == b.hashValue)
    }
}
```

Run it (it will not compile yet — the cases don't exist):

```
make build-tests
```

Expected: compile error referencing `ReaderCardItem.bookmark` / `.ankiCard` being unknown members.

- [ ] **Step 2: Add the cases and identity**

Replace the body of `enum ReaderCardItem` and its `Hashable` extension in `EchoCore/Models/ReaderCardItem.swift` (keep `extension ReaderCardItem: Sendable {}` as-is at the end):

```swift
/// Items displayed in the EPUB reader feed.
enum ReaderCardItem {
    /// A divider between chapters showing the chapter title.
    case chapterHeader(title: String, chapterIndex: Int)
    /// An EPUB block (heading, paragraph, or image).
    case block(EPubBlockRecord)
    /// A bookmark threaded inline at its chapter position.
    case bookmark(BookmarkRecord)
    /// An Anki/study flashcard threaded inline at its source-block (or timestamp) position.
    case ankiCard(Flashcard)

    var id: String {
        switch self {
        case .chapterHeader(_, let chapterIndex):
            return "ch-\(chapterIndex)"
        case .block(let block):
            return "b-\(block.id)"
        case .bookmark(let record):
            return "bm-\(record.id)"
        case .ankiCard(let card):
            return "fc-\(card.id)"
        }
    }
}

extension ReaderCardItem: Hashable {
    nonisolated static func == (lhs: ReaderCardItem, rhs: ReaderCardItem) -> Bool {
        switch (lhs, rhs) {
        case let (.chapterHeader(a1, a2), .chapterHeader(b1, b2)):
            return a1 == b1 && a2 == b2
        case let (.block(a), .block(b)):
            return a == b
        case let (.bookmark(a), .bookmark(b)):
            return a.id == b.id && a.modifiedAt == b.modifiedAt
        case let (.ankiCard(a), .ankiCard(b)):
            return a.id == b.id && a.modifiedAt == b.modifiedAt
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
        case .bookmark(let record):
            hasher.combine(2)
            hasher.combine(record.id)
            hasher.combine(record.modifiedAt)
        case .ankiCard(let card):
            hasher.combine(3)
            hasher.combine(card.id)
            hasher.combine(card.modifiedAt)
        }
    }
}
```

Rationale: `==`/`hash` use `id` + `modifiedAt` rather than full-struct equality so the diffable data source *reconfigures* a cell when a bookmark/card is edited (its `modifiedAt` bumps) without forcing the whole `BookmarkRecord`/`Flashcard` to be `Hashable` (they are not). The leading `hasher.combine(N)` keeps case tags distinct.

- [ ] **Step 3: Run the test**

```
make build-tests && make test-only FILTER=EchoTests/ReaderCardItemPhase2Tests
```

Expected: `Test run with 4 tests passed`.

- [ ] **Step 4: Commit**

```
git add EchoCore/Models/ReaderCardItem.swift EchoTests/ReaderCardItemPhase2Tests.swift
git commit -m "feat(feed): add ReaderCardItem .bookmark and .ankiCard cases"
```

---

## Task 2: `OffStateResolver` + `ChapterOffState` (one truth, two writes)

The audio off-flag lives in `.echoplaylist.json` (`PlaylistManifestService`); the EPUB off-flag lives in `epub_block.is_hidden` (GRDB). The feed must read **one** truth and the menu must write the **correct** flag(s). This pure service does both. It is UIKit-free and lives in `Shared/` so macOS can reuse it.

Because the audio layer is per-*track*, not per-*chapter*, the resolver takes the set of track files that back a chapter (the caller maps chapter → track files; for the common single-track m4b this is the one file). A chapter is "audio off" iff **every** backing track has `enabled == false`; "narration" is treated identically to audio for the manifest (narrated books still produce tracks with `enabled`). The EPUB side is "off" iff the chapter's blocks are `is_hidden`.

**Files:**
- Create: `Shared/OffStateResolver.swift`
- Test: `EchoTests/OffStateResolverTests.swift`

**Interfaces:**
- Produces:
  - `enum ChapterOffState: Equatable, Sendable { case allOn; case audioOff; case epubOff; case allOff }`
  - `struct OffStateResolver { let db: DatabaseWriter; let folderURL: URL? }`
  - `func resolve(audiobookID: String, chapterIndex: Int, trackFiles: [String]) throws -> ChapterOffState`
  - `func setEpubOff(_ off: Bool, audiobookID: String, chapterIndex: Int) throws`
  - `func setAudioOff(_ off: Bool, trackFiles: [String]) throws` (no-op if `folderURL == nil`)
  - `func setAllOff(_ off: Bool, audiobookID: String, chapterIndex: Int, trackFiles: [String]) throws`
- Consumes: `EPubBlockDAO.hideChapter`/`unhideChapter`, `EPubBlockDAO.blocks(for:chapterIndex:)`, `PlaylistManifestService.read`/`updateEnabledStates`.

- [ ] **Step 1: Write the failing test**

Create `EchoTests/OffStateResolverTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB
import Testing

@testable import Echo

@Suite struct OffStateResolverTests {
    /// Seed two blocks in chapter 0 (a heading + a paragraph) for "book-1".
    private func seed() throws -> DatabaseService {
        let db = try DatabaseService(inMemory: ())
        try db.write { db in
            // D2 fix: `duration` is NOT NULL with no default in Schema_V1.
            try db.execute(
                sql: """
                    INSERT INTO audiobook (id, title, duration) VALUES ('book-1', 'Book One', 0)
                    """)
            // D1 fix: epub_block has no `block_type` or `level` columns; the column
            // is `block_kind`, and `spine_href/spine_index/block_index` are all NOT NULL.
            try db.execute(
                sql: """
                    INSERT INTO epub_block
                      (id, audiobook_id, spine_href, spine_index, block_index,
                       sequence_index, block_kind, text,
                       chapter_index, is_hidden, created_at, modified_at)
                    VALUES
                      ('ch0-h', 'book-1', 'ch0.xhtml', 0, 0,
                       0, 'heading', 'Chapter One',
                       0, 0, '2026-06-22T00:00:00Z', '2026-06-22T00:00:00Z'),
                      ('ch0-p', 'book-1', 'ch0.xhtml', 0, 1,
                       1, 'paragraph', 'Body text',
                       0, 0, '2026-06-22T00:00:00Z', '2026-06-22T00:00:00Z')
                    """)
        }
        return db
    }

    /// Write a `.echoplaylist.json` with the given track-enabled states.
    private func writeManifest(_ folder: URL, tracks: [(file: String, enabled: Bool)]) {
        let manifest = EchoPlaylistManifest(
            version: 1, title: "Book One", author: nil,
            tracks: tracks.map {
                EchoPlaylistManifest.ManifestTrack(
                    file: $0.file, title: nil, duration: 60, enabled: $0.enabled)
            },
            // D4 fix: `lastTrackId: String?` has no `= nil` default; must be explicit.
            playbackState: EchoPlaylistManifest.ManifestPlaybackState(lastTrackId: nil),
            bookmarks: nil)
        PlaylistManifestService.write(manifest, to: folder)
    }

    private func tempFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("offstate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func freshChapterIsAllOn() throws {
        let db = try seed()
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        writeManifest(folder, tracks: [("c0.m4b", true)])
        let resolver = OffStateResolver(db: db.writer, folderURL: folder)
        let state = try resolver.resolve(
            audiobookID: "book-1", chapterIndex: 0, trackFiles: ["c0.m4b"])
        #expect(state == .allOn)
    }

    @Test func hidingEpubMakesItEpubOff() throws {
        let db = try seed()
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        writeManifest(folder, tracks: [("c0.m4b", true)])
        let resolver = OffStateResolver(db: db.writer, folderURL: folder)
        try resolver.setEpubOff(true, audiobookID: "book-1", chapterIndex: 0)
        let state = try resolver.resolve(
            audiobookID: "book-1", chapterIndex: 0, trackFiles: ["c0.m4b"])
        #expect(state == .epubOff)
    }

    @Test func disablingAllTracksMakesItAudioOff() throws {
        let db = try seed()
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        writeManifest(folder, tracks: [("c0.m4b", true)])
        let resolver = OffStateResolver(db: db.writer, folderURL: folder)
        try resolver.setAudioOff(true, trackFiles: ["c0.m4b"])
        let state = try resolver.resolve(
            audiobookID: "book-1", chapterIndex: 0, trackFiles: ["c0.m4b"])
        #expect(state == .audioOff)
    }

    @Test func partialTrackDisableIsNotAudioOff() throws {
        let db = try seed()
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        writeManifest(folder, tracks: [("a.m4b", false), ("b.m4b", true)])
        let resolver = OffStateResolver(db: db.writer, folderURL: folder)
        let state = try resolver.resolve(
            audiobookID: "book-1", chapterIndex: 0, trackFiles: ["a.m4b", "b.m4b"])
        // Only ALL-tracks-off counts as audio off.
        #expect(state == .allOn)
    }

    @Test func setAllOffMakesItAllOffThenAllOnAgain() throws {
        let db = try seed()
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        writeManifest(folder, tracks: [("c0.m4b", true)])
        let resolver = OffStateResolver(db: db.writer, folderURL: folder)
        try resolver.setAllOff(
            true, audiobookID: "book-1", chapterIndex: 0, trackFiles: ["c0.m4b"])
        #expect(
            try resolver.resolve(
                audiobookID: "book-1", chapterIndex: 0, trackFiles: ["c0.m4b"]) == .allOff)
        try resolver.setAllOff(
            false, audiobookID: "book-1", chapterIndex: 0, trackFiles: ["c0.m4b"])
        #expect(
            try resolver.resolve(
                audiobookID: "book-1", chapterIndex: 0, trackFiles: ["c0.m4b"]) == .allOn)
    }

    @Test func noManifestTreatsAudioAsOn() throws {
        let db = try seed()
        let resolver = OffStateResolver(db: db.writer, folderURL: nil)
        let state = try resolver.resolve(
            audiobookID: "book-1", chapterIndex: 0, trackFiles: ["c0.m4b"])
        #expect(state == .allOn)
    }
}
```

Run it (won't compile — `OffStateResolver` doesn't exist):

```
make build-tests
```

Expected: compile error `cannot find 'OffStateResolver' in scope`.

- [ ] **Step 2: Implement the resolver**

Create `Shared/OffStateResolver.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

/// The single reconciled on/off state of one feed chapter, derived from the two
/// independent persistence systems: audio (`.echoplaylist.json` track `enabled`
/// flags) and EPUB text (`epub_block.is_hidden`).
enum ChapterOffState: Equatable, Sendable {
    /// Both audio and EPUB are on.
    case allOn
    /// Audio is off (all backing tracks disabled) but EPUB text is visible.
    case audioOff
    /// EPUB text is hidden but audio is on.
    case epubOff
    /// Both off.
    case allOff

    var isAudioOff: Bool { self == .audioOff || self == .allOff }
    var isEpubOff: Bool { self == .epubOff || self == .allOff }
    /// Whether the whole chapter should render greyed-out (anything is off).
    var isDimmed: Bool { self != .allOn }
}

/// Reconciles the two off-switch systems into one read truth, and performs the
/// correct write per heading kind. Pure (no UIKit); reusable on macOS.
///
/// - Audio off lives in `.echoplaylist.json` (`PlaylistManifestService`), keyed
///   per *track file*. A chapter is audio-off iff **all** of its backing track
///   files have `enabled == false`.
/// - EPUB off lives in `epub_block.is_hidden` (GRDB), keyed per `chapter_index`.
struct OffStateResolver {
    let db: DatabaseWriter
    /// The playlist folder holding `.echoplaylist.json`. `nil` for books with no
    /// audio sidecar (e.g. text-only / not-yet-synced) — audio then reads as on.
    let folderURL: URL?

    // MARK: Read

    func resolve(audiobookID: String, chapterIndex: Int, trackFiles: [String]) throws
        -> ChapterOffState
    {
        let epubOff = try isEpubChapterHidden(audiobookID: audiobookID, chapterIndex: chapterIndex)
        let audioOff = isAudioOff(trackFiles: trackFiles)
        switch (audioOff, epubOff) {
        case (false, false): return .allOn
        case (true, false): return .audioOff
        case (false, true): return .epubOff
        case (true, true): return .allOff
        }
    }

    /// A chapter's EPUB text is hidden iff it has at least one block and *every*
    /// block is `is_hidden`. (A chapter with zero blocks reads as not-hidden.)
    private func isEpubChapterHidden(audiobookID: String, chapterIndex: Int) throws -> Bool {
        try db.read { db in
            let total = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM epub_block
                    WHERE audiobook_id = ? AND chapter_index = ?
                    """,
                arguments: [audiobookID, chapterIndex]) ?? 0
            guard total > 0 else { return false }
            let visible = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM epub_block
                    WHERE audiobook_id = ? AND chapter_index = ? AND is_hidden = 0
                    """,
                arguments: [audiobookID, chapterIndex]) ?? 0
            return visible == 0
        }
    }

    /// Audio is off iff there is a manifest, the chapter has backing tracks, and
    /// every backing track is disabled.
    private func isAudioOff(trackFiles: [String]) -> Bool {
        guard let folderURL, !trackFiles.isEmpty,
            let manifest = PlaylistManifestService.read(from: folderURL)
        else { return false }
        let backing = trackFiles
            .compactMap { file in manifest.tracks.first(where: { $0.file == file }) }
        guard !backing.isEmpty else { return false }
        return backing.allSatisfy { !$0.enabled }
    }

    // MARK: Write

    func setEpubOff(_ off: Bool, audiobookID: String, chapterIndex: Int) throws {
        let dao = EPubBlockDAO(db: db)
        if off {
            try dao.hideChapter(
                chapterIndex: chapterIndex, audiobookID: audiobookID, reason: "userOff")
        } else {
            try dao.unhideChapter(chapterIndex: chapterIndex, audiobookID: audiobookID)
        }
    }

    func setAudioOff(_ off: Bool, trackFiles: [String]) throws {
        guard let folderURL, !trackFiles.isEmpty else { return }
        var states: [String: Bool] = [:]
        for file in trackFiles { states[file] = !off }  // enabled = !off
        PlaylistManifestService.updateEnabledStates(folderURL: folderURL, states: states)
    }

    /// Best-effort "turn off everywhere": write GRDB first (the feed-truth side),
    /// then the manifest. If the manifest write is impossible (no folder) the EPUB
    /// write still stands and the feed renders correctly.
    func setAllOff(
        _ off: Bool, audiobookID: String, chapterIndex: Int, trackFiles: [String]
    ) throws {
        try setEpubOff(off, audiobookID: audiobookID, chapterIndex: chapterIndex)
        try setAudioOff(off, trackFiles: trackFiles)
    }
}
```

- [ ] **Step 3: Run the test**

```
make build-tests && make test-only FILTER=EchoTests/OffStateResolverTests
```

Expected: `Test run with 7 tests passed`. (If `PlaylistManifestService.write` requires the folder to pre-exist, the helper already creates it; if `updateEnabledStates` silently no-ops on a missing file, the `setAudioOff`/`setAllOff` tests still pass because the helper wrote the manifest first.)

- [ ] **Step 4: Commit**

```
git add Shared/OffStateResolver.swift EchoTests/OffStateResolverTests.swift
git commit -m "feat(feed): add OffStateResolver reconciling audio isEnabled and epub is_hidden"
```

---

## Task 3: Splice bookmarks & cards into chapter sections (`ReaderFeedDisplayBuilder`)

Phase 1's `ReaderFeedDisplayBuilder` turns `[ReaderCardSection]` into chapter groups → display sections containing only `.chapterHeader`/`.block`. Phase 2 adds a pure splice: given per-chapter "extras" (already-built `.bookmark`/`.ankiCard` items), insert them into each chapter group's expanded item list **in document order**. Blocks order by `sequenceIndex`; an extra anchored to a known block sorts immediately *after* that block; an extra with only a derived chapter (no block) sorts to the chapter's end. The VM does the DB derivation (Task 4); this task is the pure ordering.

**Files:**
- Modify: `EchoCore/Models/ReaderFeedDisplayBuilder.swift`
- Test: `EchoTests/ReaderFeedDisplayBuilderPhase2Tests.swift`

**Interfaces:**
- Produces (new pure entry point, additive — leave Phase 1's `displaySections(...)` untouched):
  `static func spliceExtras(into items: [ReaderCardItem], extras: [SplicedExtra]) -> [ReaderCardItem]`
  where `struct SplicedExtra { let item: ReaderCardItem; let afterBlockID: String? }`.

> NOTE: Phase 1's exact internal helper names (`ReaderChapterGroup`, `displaySections(groups:openChapterKey:)`) are referenced here only as *callers*; this task adds a self-contained pure function the VM calls per chapter before grouping. It does **not** modify Phase 1's signatures. If Phase 1 named things differently, only the call site in Task 4 changes — this function stands alone.

- [ ] **Step 1: Write the failing test**

Create `EchoTests/ReaderFeedDisplayBuilderPhase2Tests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

@Suite struct ReaderFeedDisplayBuilderPhase2Tests {
    // D3 fix: `EPubBlockRecord` has no `blockType:` or `level:` labels; the real
    // memberwise init requires `spineHref`, `spineIndex`, `blockIndex`, `blockKind`
    // (all non-optional, no defaults). Use the correct full memberwise init.
    private func block(_ id: String, seq: Int) -> EPubBlockRecord {
        EPubBlockRecord(
            id: id, audiobookID: "book-1",
            spineHref: "ch0.xhtml", spineIndex: 0, blockIndex: seq,
            sequenceIndex: seq, blockKind: "paragraph",
            text: "t", htmlContent: nil, cardColor: nil, chapterThemeColor: nil,
            imagePath: nil, chapterIndex: 0, isHidden: false, hiddenReason: nil,
            wordCount: nil, markers: nil, textFormats: nil,
            createdAt: "2026-06-22T00:00:00Z", modifiedAt: "2026-06-22T00:00:00Z")
    }

    private func bookmark(_ id: String) -> ReaderCardItem {
        .bookmark(
            BookmarkRecord(
                id: id, audiobookID: "book-1", trackID: nil, title: "BM",
                mediaTimestamp: 1, note: nil, voiceMemoPath: nil, imagePath: nil,
                isEnabled: true, playlistPosition: nil, pdfViewStateJSON: nil,
                latitude: nil, longitude: nil, placeName: nil,
                createdAt: "2026-06-22T00:00:00Z", modifiedAt: "2026-06-22T00:00:00Z"))
    }

    @Test func extraAnchoredToBlockSortsRightAfterIt() {
        let items: [ReaderCardItem] = [
            .block(block("a", seq: 0)), .block(block("b", seq: 1)),
        ]
        let result = ReaderFeedDisplayBuilder.spliceExtras(
            into: items,
            extras: [.init(item: bookmark("bm1"), afterBlockID: "a")])
        #expect(result.map(\.id) == ["b-a", "bm-bm1", "b-b"])
    }

    @Test func unanchoredExtraSortsToEnd() {
        let items: [ReaderCardItem] = [
            .block(block("a", seq: 0)), .block(block("b", seq: 1)),
        ]
        let result = ReaderFeedDisplayBuilder.spliceExtras(
            into: items,
            extras: [.init(item: bookmark("bm1"), afterBlockID: nil)])
        #expect(result.map(\.id) == ["b-a", "b-b", "bm-bm1"])
    }

    @Test func multipleExtrasAfterSameBlockKeepStableOrder() {
        let items: [ReaderCardItem] = [.block(block("a", seq: 0))]
        let result = ReaderFeedDisplayBuilder.spliceExtras(
            into: items,
            extras: [
                .init(item: bookmark("bm1"), afterBlockID: "a"),
                .init(item: bookmark("bm2"), afterBlockID: "a"),
            ])
        #expect(result.map(\.id) == ["b-a", "bm-bm1", "bm-bm2"])
    }

    @Test func anchorToUnknownBlockFallsBackToEnd() {
        let items: [ReaderCardItem] = [.block(block("a", seq: 0))]
        let result = ReaderFeedDisplayBuilder.spliceExtras(
            into: items,
            extras: [.init(item: bookmark("bm1"), afterBlockID: "ghost")])
        #expect(result.map(\.id) == ["b-a", "bm-bm1"])
    }

    @Test func chapterHeaderStaysFirst() {
        let items: [ReaderCardItem] = [
            .chapterHeader(title: "Chapter One", chapterIndex: 0),
            .block(block("a", seq: 0)),
        ]
        let result = ReaderFeedDisplayBuilder.spliceExtras(
            into: items,
            extras: [.init(item: bookmark("bm1"), afterBlockID: "a")])
        #expect(result.map(\.id) == ["ch-0", "b-a", "bm-bm1"])
    }
}
```

Run it (won't compile — `spliceExtras`/`SplicedExtra` don't exist):

```
make build-tests
```

Expected: compile error referencing `spliceExtras` / `SplicedExtra`.

- [ ] **Step 2: Add the pure splice**

Append to `EchoCore/Models/ReaderFeedDisplayBuilder.swift` (inside the existing `enum`/`struct ReaderFeedDisplayBuilder` namespace — if it is declared `enum ReaderFeedDisplayBuilder {`, add these members before its closing brace; the snippet is self-contained either way):

```swift
extension ReaderFeedDisplayBuilder {
    /// An extra feed item (bookmark or card) plus the id of the block it should
    /// appear immediately after. `nil` `afterBlockID` (or an unknown one) sends it
    /// to the end of the chapter's items.
    struct SplicedExtra {
        let item: ReaderCardItem
        let afterBlockID: String?
    }

    /// Insert `extras` into `items` (one chapter's items, in document order) so
    /// each anchored extra appears right after its block, preserving the relative
    /// order of multiple extras on the same block, and unanchored extras land at
    /// the end. `.chapterHeader` and `.block` ordering is left untouched.
    static func spliceExtras(into items: [ReaderCardItem], extras: [SplicedExtra])
        -> [ReaderCardItem]
    {
        guard !extras.isEmpty else { return items }

        // Group extras by the block id they trail. Unknown/nil anchors go to a
        // dedicated "tail" bucket appended last.
        let knownBlockIDs: Set<String> = Set(
            items.compactMap { if case .block(let b) = $0 { return b.id } else { return nil } })

        var afterBlock: [String: [ReaderCardItem]] = [:]
        var tail: [ReaderCardItem] = []
        for extra in extras {
            if let anchor = extra.afterBlockID, knownBlockIDs.contains(anchor) {
                afterBlock[anchor, default: []].append(extra.item)
            } else {
                tail.append(extra.item)
            }
        }

        var result: [ReaderCardItem] = []
        result.reserveCapacity(items.count + extras.count)
        for item in items {
            result.append(item)
            if case .block(let b) = item, let trailing = afterBlock[b.id] {
                result.append(contentsOf: trailing)
            }
        }
        result.append(contentsOf: tail)
        return result
    }
}
```

- [ ] **Step 3: Run the test**

```
make build-tests && make test-only FILTER=EchoTests/ReaderFeedDisplayBuilderPhase2Tests
```

Expected: `Test run with 5 tests passed`.

- [ ] **Step 4: Commit**

```
git add EchoCore/Models/ReaderFeedDisplayBuilder.swift EchoTests/ReaderFeedDisplayBuilderPhase2Tests.swift
git commit -m "feat(feed): splice bookmarks and cards into chapter items in document order"
```

---

## Task 4: View-model wiring — fetch, bucket, off-state

`ReaderFeedViewModel.reload()` now also fetches bookmarks + flashcards, derives each one's `(chapterIndex, afterBlockID)`, builds `.bookmark`/`.ankiCard` items, and feeds them per chapter through `spliceExtras`. The VM also injects an `OffStateResolver` and exposes read/write helpers for the menu, plus observes `.timelineItemsIngested` so newly captured items appear without a manual reload.

**Files:**
- Modify: `EchoCore/ViewModels/ReaderFeedViewModel.swift`
- Test: covered by Tasks 1–3 (pure) + the smoke build in Task 7. (VM is `@MainActor` + DB-bound; its bucketing logic is exercised by `ReaderFeedDisplayBuilder` tests; a heavier VM integration test is optional and deferred to keep the build slot free.)

**Interfaces:**
- Consumes: `BookmarkDAO.bookmarks(for:)`, `FlashcardDAO.flashcards(for:)`, `EPubBlockDAO.blocks(for:chapterIndex:)`, `AlignmentAnchorDAO` (for timestamp→chapter), `OffStateResolver`, `ReaderFeedDisplayBuilder.spliceExtras`.
- Produces: `func chapterOffState(_ chapterIndex: Int) -> ChapterOffState`, `func setChapterOff(_ kind: OffKind, on: Bool, chapterIndex: Int)`, `enum OffKind { case all, audio, epub }`, and updated `displaySections` that include spliced extras.

- [ ] **Step 1: Add the dependency + storage**

In `EchoCore/ViewModels/ReaderFeedViewModel.swift`, add stored properties near the existing DAOs (after `private let chapterDAO`) and extend `init`. Find the existing init at `…:86`:

```swift
init(audiobookID: String, db: DatabaseWriter) {
    self.audiobookID = audiobookID
    self.blockDAO = EPubBlockDAO(db: db)
    self.chapterDAO = ChapterDAO(db: db)
    self.db = db
}
```

Replace it with (adds bookmark/flashcard/anchor DAOs, the resolver, the playlist folder, and an off-state cache):

```swift
private let bookmarkDAO: BookmarkDAO
private let flashcardDAO: FlashcardDAO
private let anchorDAO: AlignmentAnchorDAO
private let offResolver: OffStateResolver
/// Playlist folder for `.echoplaylist.json` (audio off lives here). May be nil
/// for text-only books.
private let playlistFolderURL: URL?
/// Cached chapter → backing-track files (filled in `reload`). Single-track m4b
/// books map their one file to every chapter.
private var trackFilesByChapter: [Int: [String]] = [:]
/// Cached off-state per chapter, recomputed in `reload`.
private(set) var offStateByChapter: [Int: ChapterOffState] = [:]

init(audiobookID: String, db: DatabaseWriter, playlistFolderURL: URL? = nil) {
    self.audiobookID = audiobookID
    self.blockDAO = EPubBlockDAO(db: db)
    self.chapterDAO = ChapterDAO(db: db)
    self.bookmarkDAO = BookmarkDAO(db: db)
    self.flashcardDAO = FlashcardDAO(db: db)
    self.anchorDAO = AlignmentAnchorDAO(db: db)
    self.playlistFolderURL = playlistFolderURL
    self.offResolver = OffStateResolver(db: db, folderURL: playlistFolderURL)
    self.db = db
}
```

> The caller that constructs `ReaderFeedViewModel` (search for `ReaderFeedViewModel(audiobookID:`) must pass the book's playlist folder URL if it has one. If the current callers only pass `audiobookID:db:`, the new `playlistFolderURL` defaults to `nil` (audio off then reads as on — acceptable; EPUB off still works). Update the real call site in `ReaderTab`/its container to pass the folder if readily available.

- [ ] **Step 2: Derive each extra's chapter + anchor block, then splice**

Add a private helper to the VM (anywhere in the type body), which buckets bookmarks/cards and returns per-chapter extras keyed by chapter index:

```swift
/// Build `.bookmark`/`.ankiCard` extras bucketed by chapter index, each tagged
/// with the block id it should trail (or nil → chapter end).
private func buildExtrasByChapter() -> [Int: [ReaderFeedDisplayBuilder.SplicedExtra]] {
    var byChapter: [Int: [ReaderFeedDisplayBuilder.SplicedExtra]] = [:]

    // Cards: prefer the precise sourceBlockID; else derive from timestamp.
    let cards = (try? flashcardDAO.flashcards(for: audiobookID)) ?? []
    for card in cards {
        let (chapter, blockID) = placement(
            sourceBlockID: card.sourceBlockID, mediaTimestamp: card.mediaTimestamp)
        byChapter[chapter, default: []].append(
            .init(item: .ankiCard(card), afterBlockID: blockID))
    }

    // Bookmarks: no source block — always timestamp-derived.
    let bookmarks = (try? bookmarkDAO.bookmarks(for: audiobookID)) ?? []
    for bm in bookmarks {
        let (chapter, blockID) = placement(
            sourceBlockID: nil, mediaTimestamp: bm.mediaTimestamp)
        byChapter[chapter, default: []].append(
            .init(item: .bookmark(bm), afterBlockID: blockID))
    }
    return byChapter
}

/// Resolve an item to `(chapterIndex, afterBlockID?)`. If `sourceBlockID` is
/// known, look up its chapter directly; otherwise find the alignment anchor at or
/// before `mediaTimestamp` and use its block. Unresolvable → (-1, nil) (front
/// matter bucket) so the item is never dropped.
private func placement(sourceBlockID: String?, mediaTimestamp: TimeInterval)
    -> (chapter: Int, blockID: String?)
{
    // S2 fix: `chapterIndexByBlockID[key]` is `Int??` (Optional<Optional<Int>>).
    // Flatten with `?? nil` before the outer `let` so the binding is `Int?`, then
    // guard with a second `let` for the non-nil check. The original `let idx …, let idx`
    // double-binding and the un-flattened `??` were both compile errors.
    if let sourceBlockID {
        let looked: Int? = (chapterIndexByBlockID[sourceBlockID] ?? nil)
            ?? lookupChapter(ofBlock: sourceBlockID)
        if let idx = looked {
            return (idx, sourceBlockID)
        }
    }
    if let block = anchorDAO.block(at: mediaTimestamp, audiobookID: audiobookID),
        let idx = lookupChapter(ofBlock: block)
    {
        return (idx, block)
    }
    return (-1, nil)
}

private func lookupChapter(ofBlock blockID: String) -> Int? {
    if let cached = chapterIndexByBlockID[blockID] { return cached }
    let idx = try? db.read { db in
        try Int.fetchOne(
            db,
            sql: "SELECT chapter_index FROM epub_block WHERE id = ?",
            arguments: [blockID])
    }
    return idx ?? nil
}
```

> `AlignmentAnchorDAO.block(at:audiobookID:)` — this method does not yet exist; add it to `Shared/Database/DAOs/AlignmentAnchorDAO.swift` (Task 4 Step 7 stages the file, so this addition is mandatory):
> ```swift
> /// The epub_block id of the alignment anchor at or immediately before `time`.
> func block(at time: TimeInterval, audiobookID: String) -> String? {
>     try? db.read { db in
>         try String.fetchOne(
>             db,
>             sql: """
>                 SELECT epub_block_id FROM alignment_anchor
>                 WHERE audiobook_id = ? AND audio_time <= ?
>                 ORDER BY audio_time DESC LIMIT 1
>                 """,
>             arguments: [audiobookID, time])
>     } ?? nil
> }
> ```
> Verify the actual column names against `AlignmentAnchorDAO`/the `alignment_anchor` schema before pasting (the recon brief uses `audio_time` and `epub_block_id`).

- [ ] **Step 3: Call the splice in `reload()` and refresh off-state**

In `reload()`, after `parsedSections` (the per-chapter `ReaderCardSection`s) are built and assigned to `sections`, but before Phase-1 grouping into `displaySections`, splice the extras per chapter and recompute off-state. Add at the end of the non-search branch of `reload()` (right before the Phase-1 `displaySections` build):

```swift
// --- Phase 2: thread bookmarks + cards into their chapter sections. ---
let extrasByChapter = buildExtrasByChapter()
if !extrasByChapter.isEmpty {
    sections = sections.map { section in
        // section.id is "ch<key>-s<n>"; the chapter key is the audio chapter index.
        guard let key = Self.chapterKey(ofSectionID: section.id),
            let extras = extrasByChapter[key], !extras.isEmpty
        else { return section }
        let merged = ReaderFeedDisplayBuilder.spliceExtras(into: section.items, extras: extras)
        return ReaderCardSection(
            id: section.id, headingStack: section.headingStack, items: merged)
    }
}

// --- Phase 2: recompute reconciled off-state per chapter. ---
refreshOffState()
```

Add the helpers (chapter-key parsing matches Phase 1's `"ch\(key)-s\(n)"` id format; front matter is `-1` with id `"ch-1-s0"`):

```swift
/// Parse the audio chapter index out of a section id "ch<key>-s<n>".
/// Front matter is "ch-1-s0" → -1.
static func chapterKey(ofSectionID id: String) -> Int? {
    guard id.hasPrefix("ch") else { return nil }
    // Strip "ch", then take everything up to "-s".
    let afterCh = id.dropFirst(2)
    guard let sRange = afterCh.range(of: "-s") else { return nil }
    return Int(afterCh[..<sRange.lowerBound])
}

/// Recompute the reconciled off-state for every chapter that has sections.
func refreshOffState() {
    var result: [Int: ChapterOffState] = [:]
    let keys = Set(sections.compactMap { Self.chapterKey(ofSectionID: $0.id) })
    for key in keys where key >= 0 {
        let files = trackFilesByChapter[key] ?? allTrackFiles()
        result[key] = (try? offResolver.resolve(
            audiobookID: audiobookID, chapterIndex: key, trackFiles: files)) ?? .allOn
    }
    offStateByChapter = result
}

/// All track files from the manifest (fallback when a per-chapter map is absent).
private func allTrackFiles() -> [String] {
    guard let playlistFolderURL,
        let manifest = PlaylistManifestService.read(from: playlistFolderURL)
    else { return [] }
    return manifest.tracks.map(\.file)
}
```

> **Trap (Trap C / per-chapter audio):** the resolver needs the *backing track files for a chapter*. A precise chapter→track map requires joining `chapter.start_seconds/end_seconds` against track ordering, which the VM does not yet build. For v1 we use `allTrackFiles()` (every track) as the fallback, meaning "audio off" for a single-track book is exact, and for multi-track books "turn off listening" disables the whole book's audio. This is a documented v1 limitation — flagged for owner. A precise map is a follow-up.

- [ ] **Step 4: Public off-state read/write API for the menu**

Add to the VM body:

```swift
enum OffKind { case all, audio, epub }

func chapterOffState(_ chapterIndex: Int) -> ChapterOffState {
    offStateByChapter[chapterIndex] ?? .allOn
}

/// Apply an off/on toggle for one chapter, write through the resolver, then
/// reload so the feed (grey-out + visibility) reflects the new truth.
func setChapterOff(_ kind: OffKind, on: Bool, chapterIndex: Int) {
    let files = trackFilesByChapter[chapterIndex] ?? allTrackFiles()
    do {
        switch kind {
        case .all:
            try offResolver.setAllOff(
                on, audiobookID: audiobookID, chapterIndex: chapterIndex, trackFiles: files)
        case .audio:
            try offResolver.setAudioOff(on, trackFiles: files)
        case .epub:
            try offResolver.setEpubOff(on, audiobookID: audiobookID, chapterIndex: chapterIndex)
        }
    } catch {
        // Best-effort: GRDB write may have landed even if the manifest write did
        // not. Log only; the reload below re-reads whatever truth persisted.
        print("[ReaderFeedViewModel] setChapterOff failed: \(error)")
    }
    reload()
}
```

- [ ] **Step 5: Observe `.timelineItemsIngested`**

So newly captured bookmarks/cards splice in without a manual reload, add an observer. In `init` (after the resolver is set up), register:

```swift
NotificationCenter.default.addObserver(
    forName: Notification.Name("timelineItemsIngested"),
    object: nil, queue: .main
) { [weak self] _ in
    self?.reload()
}
```

> Verify the exact notification name constant used by the capture path (the recon cites `.timelineItemsIngested` observed at `PlaylistView.swift:434`). If it is declared as a `Notification.Name` extension, use that symbol instead of the raw string. This observer *replaces* the one being deleted with `PlaylistView` in Task 6.

- [ ] **Step 6: Build**

```
make build-tests
```

Expected: build succeeds (no test target for the VM here; Tasks 1–3 suites still pass). If `BookmarkDAO`/`FlashcardDAO`/`AlignmentAnchorDAO` are not in the iOS-target membership for this file's module, confirm they compile in EchoCore (they are `Shared/` DAOs already used by other EchoCore code).

- [ ] **Step 7: Commit**

```
git add EchoCore/ViewModels/ReaderFeedViewModel.swift Shared/Database/DAOs/AlignmentAnchorDAO.swift
git commit -m "feat(feed): thread bookmarks/cards into feed sections and reconcile chapter off-state in the VM"
```

---

## Task 5: Cells for `.bookmark` / `.ankiCard` + grey-out + long-press off menu

Render the two new item types, dim off chapters, and add the long-press `UIMenu` on chapter-header rows — the *only* place "off" lives.

**Files:**
- Modify: `EchoCore/Views/ReaderFeedCollectionView.swift`
- Modify: `EchoCore/Views/ReaderTab.swift`

**Interfaces:**
- Produces: `BookmarkFeedCell`, `AnkiCardFeedCell` registered in the diffable source; `cell(for:)` dispatch for `.bookmark`/`.ankiCard`; `ChapterDividerCell.configure(title:hasAudio:isExpanded:offState:)` (adds `offState` with default `.allOn`); a chapter-header context menu provider; new closures `onChapterHeaderContextMenu: ((Int) -> UIContextMenuConfiguration?)?` and `offState: (Int) -> ChapterOffState`.

- [ ] **Step 1: Register the new cells**

In `ReaderFeedCollectionView` `makeUIView`/setup where the registry lives (`…:65`–`:72`), add after the `ChapterDividerCell` registration:

```swift
collectionView.register(
    BookmarkFeedCell.self, forCellWithReuseIdentifier: BookmarkFeedCell.reuseIdentifier)
collectionView.register(
    AnkiCardFeedCell.self, forCellWithReuseIdentifier: AnkiCardFeedCell.reuseIdentifier)
```

- [ ] **Step 2: Dispatch the new item types in `cell(for:)`**

In `cell(for:)` (`…:247`), add cases after the existing `.block` case (before the final `return` / default):

```swift
// D6 fix: `cardTint` is a local computed inside each `.block` sub-branch and is
// not in scope at the `switch item` level. Compute the tint independently here.
case .bookmark(let record):
    let tint = UIColor(hex: settings.cardTintHex) ?? .systemBackground
    let cell =
        collectionView.dequeueReusableCell(
            withReuseIdentifier: BookmarkFeedCell.reuseIdentifier, for: indexPath
        ) as? BookmarkFeedCell ?? BookmarkFeedCell()
    cell.configure(with: record, tint: tint)
    return cell

case .ankiCard(let card):
    let tint = UIColor(hex: settings.cardTintHex) ?? .systemBackground
    let cell =
        collectionView.dequeueReusableCell(
            withReuseIdentifier: AnkiCardFeedCell.reuseIdentifier, for: indexPath
        ) as? AnkiCardFeedCell ?? AnkiCardFeedCell()
    cell.configure(with: card, tint: tint)
    return cell
```

> `UIColor(hex:)` is the extension already used in the existing `.block` cells. If the real call site uses a different expression to derive the tint (e.g. a coordinator property), use that same expression — the key constraint (D6) is that `cardTint` is not a shared local at the `switch` level, so each case must compute its own value.

- [ ] **Step 3: Define the two cells**

Add to the bottom of `ReaderFeedCollectionView.swift` (near `ChapterDividerCell` at `…:605`):

```swift
// MARK: - Bookmark cell

private final class BookmarkFeedCell: UICollectionViewCell {
    static let reuseIdentifier = "BookmarkFeedCell"

    private let icon = UIImageView()
    private let titleLabel = UILabel()
    private let noteLabel = UILabel()
    private let container = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        container.translatesAutoresizingMaskIntoConstraints = false
        container.layer.cornerRadius = 10
        container.layer.cornerCurve = .continuous
        contentView.addSubview(container)

        icon.image = UIImage(systemName: "bookmark.fill")
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.numberOfLines = 2
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        noteLabel.font = .preferredFont(forTextStyle: .subheadline)
        noteLabel.textColor = .secondaryLabel
        noteLabel.numberOfLines = 3
        noteLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [titleLabel, noteLabel])
        stack.axis = .vertical
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(icon)
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            container.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            container.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            container.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            icon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            icon.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            stack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with record: BookmarkRecord, tint: UIColor) {
        titleLabel.text = record.title
        noteLabel.text = record.note
        noteLabel.isHidden = (record.note ?? "").isEmpty
        icon.tintColor = tint
        container.backgroundColor = tint.withAlphaComponent(0.08)
    }
}

// MARK: - Anki card cell

private final class AnkiCardFeedCell: UICollectionViewCell {
    static let reuseIdentifier = "AnkiCardFeedCell"

    private let icon = UIImageView()
    private let frontLabel = UILabel()
    private let backLabel = UILabel()
    private let container = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        container.translatesAutoresizingMaskIntoConstraints = false
        container.layer.cornerRadius = 10
        container.layer.cornerCurve = .continuous
        contentView.addSubview(container)

        icon.image = UIImage(systemName: "rectangle.on.rectangle.angled")
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false

        frontLabel.font = .preferredFont(forTextStyle: .headline)
        frontLabel.numberOfLines = 3
        frontLabel.translatesAutoresizingMaskIntoConstraints = false

        backLabel.font = .preferredFont(forTextStyle: .subheadline)
        backLabel.textColor = .secondaryLabel
        backLabel.numberOfLines = 4
        backLabel.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [frontLabel, backLabel])
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(icon)
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16),
            container.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            container.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            container.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            icon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            icon.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            icon.widthAnchor.constraint(equalToConstant: 20),
            icon.heightAnchor.constraint(equalToConstant: 20),
            stack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(with card: Flashcard, tint: UIColor) {
        frontLabel.text = card.frontText
        backLabel.text = card.backText
        backLabel.isHidden = card.backText.isEmpty
        icon.tintColor = tint
        container.backgroundColor = tint.withAlphaComponent(0.10)
        container.layer.borderWidth = 1
        container.layer.borderColor = tint.withAlphaComponent(0.25).cgColor
    }
}
```

- [ ] **Step 4: Grey-out — extend `ChapterDividerCell.configure`**

Phase 1's `ChapterDividerCell.configure(...)` exists. Add an `offState` parameter with a default so Phase 1 callers compile unchanged, and dim the cell when off. Replace the `configure` signature on `ChapterDividerCell` (Phase 1 form: `configure(title:hasAudio:isExpanded:)`; if Phase 1 shipped a different shape, add `offState` to whatever it is):

```swift
func configure(
    title: String,
    hasAudio: Bool,
    isExpanded: Bool,
    offState: ChapterOffState = .allOn
) {
    // … existing Phase 1 body (set titleLabel, audio glyph, chevron) …

    // Phase 2: dim the whole row when anything is off.
    let dimmed = offState.isDimmed
    contentView.alpha = dimmed ? 0.45 : 1.0
    titleLabel.textColor = dimmed ? .secondaryLabel : .label
}
```

> Update the `cell.configure(...)` call site in `cell(for:)` `.chapterHeader` (Phase 1 passes `hasAudio`/`isExpanded`) to also pass `offState: offState(chapterIndex)`, where `offState` is the new closure threaded from `ReaderTab` (Step 6). The `.chapterHeader` case has `chapterIndex` in scope (it is the case payload — change Phase 1's `case .chapterHeader(let title, _)` to `case .chapterHeader(let title, let chapterIndex)`).

- [ ] **Step 5: Chapter-header long-press menu**

Add the off-menu provider. The existing block context-menu provider is at `…:590` and uses the **plural** iOS 16+ selector `contextMenuConfigurationForItemsAt indexPaths: [IndexPath]`. Extend the **same** method in place (do not add a singular `…ForItemAt` overload — UIKit never calls it):

```swift
// D5 fix: extend the existing PLURAL delegate method (…ForItemsAt indexPaths:[IndexPath])
// that already lives at …:590. The singular …ForItemAt version is an iOS 13 API that
// UIKit does NOT call when the plural override is present — adding it would silently
// produce a method UIKit ignores, and the context menu would never appear on headers.
// Also: `dataSource` is Optional here — use `dataSource?`, not `dataSource.`.
func collectionView(
    _ collectionView: UICollectionView,
    contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint
) -> UIContextMenuConfiguration? {
    guard let indexPath = indexPaths.first,
        let itemID = dataSource?.itemIdentifier(for: indexPath),
        let card = card(for: itemID)
    else { return nil }
    switch card {
    case .chapterHeader(_, let chapterIndex):
        return onChapterHeaderContextMenu?(chapterIndex)
    case .block(let block):
        return onContextMenu?(block)
    default:
        return nil
    }
}
```

Add the closure to the coordinator and the representable (mirror `onContextMenu` at `…:28`/`:192`/`:223`):

```swift
// On ReaderFeedCollectionView (the UIViewRepresentable):
var onChapterHeaderContextMenu: ((Int) -> UIContextMenuConfiguration?)?
var offState: ((Int) -> ChapterOffState)?

// In makeCoordinator / updateUIView, forward both:
context.coordinator.onChapterHeaderContextMenu = onChapterHeaderContextMenu
context.coordinator.offState = offState

// On the Coordinator:
var onChapterHeaderContextMenu: ((Int) -> UIContextMenuConfiguration?)?
var offState: ((Int) -> ChapterOffState)?
```

And the `cell(for:)` `.chapterHeader` branch reads the closure: `offState?(chapterIndex) ?? .allOn`.

- [ ] **Step 6: Build the menu + wire `ReaderTab`**

In `ReaderTab` where `ReaderFeedCollectionView(...)` is constructed (`…:92`), pass the two new closures. Add after the existing `onContextMenu:` argument:

```swift
offState: { chapterIndex in vm.chapterOffState(chapterIndex) },
onChapterHeaderContextMenu: { (chapterIndex: Int) -> UIContextMenuConfiguration? in
    let state = vm.chapterOffState(chapterIndex)
    let hasAudio = vm.chapterHasAudio[chapterIndex] ?? false  // Phase 1 map

    return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
        // Turn off everywhere (toggles whole-chapter).
        let everywhereOn = (state == .allOn)
        let everywhere = UIAction(
            title: everywhereOn ? "Turn off everywhere" : "Turn on everywhere",
            image: UIImage(systemName: everywhereOn ? "eye.slash" : "eye")
        ) { _ in
            vm.setChapterOff(.all, on: everywhereOn, chapterIndex: chapterIndex)
        }

        // Granular: Listen (audio).
        let listen = UIAction(
            title: state.isAudioOff ? "Turn on listening" : "Turn off listening",
            image: UIImage(systemName: "headphones"),
            attributes: hasAudio ? [] : .disabled
        ) { _ in
            vm.setChapterOff(.audio, on: !state.isAudioOff, chapterIndex: chapterIndex)
        }

        // Granular: Narrate (treated as the same manifest audio flag this phase).
        let narrate = UIAction(
            title: state.isAudioOff ? "Turn on narration" : "Turn off narration",
            image: UIImage(systemName: "waveform"),
            attributes: hasAudio ? [] : .disabled
        ) { _ in
            vm.setChapterOff(.audio, on: !state.isAudioOff, chapterIndex: chapterIndex)
        }

        // Granular: Cards/text (epub).
        let cards = UIAction(
            title: state.isEpubOff ? "Turn on reading & cards" : "Turn off reading & cards",
            image: UIImage(systemName: "text.book.closed")
        ) { _ in
            vm.setChapterOff(.epub, on: !state.isEpubOff, chapterIndex: chapterIndex)
        }

        let granular = UIMenu(
            title: "", options: .displayInline, children: [listen, narrate, cards])
        return UIMenu(title: "", children: [everywhere, granular])
    }
}
```

> `vm.chapterHasAudio` is Phase 1's per-chapter has-audio map (the recon names it `chapterHasAudio`). If Phase 1 exposed a `Set<Int>` (`chaptersWithAudio`) instead, use `vm.chaptersWithAudio.contains(chapterIndex)`.
>
> **Narrate vs Listen overlap (documented v1 limitation):** the manifest has a single `enabled` flag per track; narrated and imported-audio books both surface it. This phase maps both "narration" and "listening" to that one flag, so toggling either flips the same state. A distinct narration off-switch is a follow-up once narration tracks are separately addressable. Flagged for owner.

- [ ] **Step 7: Build**

```
make build-tests
```

Expected: build succeeds. (Visual correctness of the cells/menu is verified on-device by the owner; there is no unit test for UIKit cells.)

- [ ] **Step 8: Commit**

```
git add EchoCore/Views/ReaderFeedCollectionView.swift EchoCore/Views/ReaderTab.swift
git commit -m "feat(feed): render bookmarks/cards inline, grey out off chapters, add long-press off menu"
```

---

## Task 6: Retire the chronological playlist; collapse Read + Study into one tab

Delete `TabSelection.timeline`, `TimelineTab`, and the chronological `PlaylistView`; relabel `.read`; remap deep links; collapse the bottom-toolbar tab cycle. Lift the bookmark-edit sheet + DailyReview trigger out of `PlaylistView` before deleting it.

**Files:**
- Modify: `Shared/TabSelection.swift`, `EchoCore/Services/DeepLinkHandler.swift`, `EchoCore/ViewModels/PlayerModel.swift`, `EchoCore/Views/RootTabView.swift`, `EchoCore/Views/BottomToolbarView.swift`, `EchoCore/Views/NowPlayingTab.swift`
- Delete: `EchoCore/Views/TimelineTab.swift`, `EchoCore/Views/PlaylistView.swift` (chronological view)

- [ ] **Step 1: Find the full blast radius first**

```
grep -rn "\.timeline\b" EchoCore Shared | grep -v "Tests"
grep -rn "TimelineTab\|PlaylistView\|timelinePath\|timelineItemsIngested" EchoCore Shared
```

Record every hit; each must be remapped or removed. Expected hits include `RootTabView.swift` (lines ~33–39, ~58–110, ~269–283, ~139), `BottomToolbarView.swift` (~120–151), `NowPlayingTab.swift` (~110), `DeepLinkHandler.swift` (~75), `PlayerModel.swift` (~1179).

- [ ] **Step 2: Delete `.timeline` from `TabSelection` and relabel `.read`**

Replace `Shared/TabSelection.swift` with:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

enum TabSelection: String, CaseIterable {
    case nowPlaying
    case read
    // .timeline removed — the Study playlist is gone; the Read feed IS the study surface.
    // .stats removed — Stats now opens as a sheet from the More menu (UnifiedTopHeader).

    var icon: String {
        switch self {
        case .nowPlaying: return "headphones"
        case .read: return "book.pages"
        }
    }

    var label: String {
        switch self {
        case .nowPlaying: return "Listen"
        case .read: return "Read & Study"
        }
    }
}
```

- [ ] **Step 3: Remap deep links**

In `EchoCore/Services/DeepLinkHandler.swift` (`:75`):

```swift
case .study:
    return .navigate(.read)
```

In `EchoCore/ViewModels/PlayerModel.swift` (`:1179`):

```swift
case .navigateToBookmark:
    selectedTab = .read
```

In `EchoCore/Views/NowPlayingTab.swift` (`:110`):

```swift
onShowBookmarks: { model.selectedTab = .read }
```

- [ ] **Step 4: Collapse the bottom-toolbar tab cycle**

In `EchoCore/Views/BottomToolbarView.swift` (`timelineButton`, ~`:120`–`:151`), rename/rewrite to a 2-state toggle. Replace the 3-state `switch` (`:124`–`:129`) and the `== .timeline || == .read` conditions (`:134`, `:144`, `:148`) so the single non-now-playing destination is `.read`:

```swift
// Was timelineButton — now a 2-state toggle: nowPlaying ↔ read.
private var readToggleButton: some View {
    Button {
        model.selectedTab = (model.selectedTab == .read) ? .nowPlaying : .read
    } label: {
        Image(systemName: model.selectedTab == .read ? "book.pages.fill" : "book.pages")
    }
    .accessibilityLabel(model.selectedTab == .read ? "Now Playing" : "Read & Study")
}
```

Update wherever `timelineButton` was referenced in the toolbar body to `readToggleButton`, and any selected-state highlight condition from `model.selectedTab == .timeline || model.selectedTab == .read` to `model.selectedTab == .read`.

- [ ] **Step 5: Remove `.timeline` from `RootTabView`**

In `EchoCore/Views/RootTabView.swift`:
- Delete `@State private var timelinePath` and its `@SceneStorage("timelinePathData")` (lines ~33–39). (Stale scene-storage data is harmless; `NavigationPath` restore is `try?`.)
- Delete the `case .timeline:` arm of the `switch model.selectedTab` (lines ~98–109) that wrapped `TimelineTab`/`PlaylistView`.
- Delete the `timelinePath` persistence in the `scenePhase` handler (lines ~269–283).
- Change `onShowBookmarks: { model.selectedTab = .timeline }` (line ~139) to `.read`.
- **Lift the sheet + review trigger:** if `PlaylistView` hosted `EditBookmarkView` (via `editingBookmarkID`) and the DailyReview trigger, host the bookmark-edit sheet and the review action from `RootTabView` (or the `.read` content) instead. Add to `RootTabView`'s `.read` content a `.sheet(item: $editingBookmark) { EditBookmarkView(...) }` and route the "review due cards" entry point (previously in `PlaylistView`) to wherever DailyReview is presented. Verify `EditBookmarkView` is defined in its own file (not nested in `PlaylistView`); if nested, move it to `EchoCore/Views/EditBookmarkView.swift` before deleting `PlaylistView`.

- [ ] **Step 6: Delete the retired files**

```
git rm EchoCore/Views/TimelineTab.swift
git rm EchoCore/Views/PlaylistView.swift
```

> Before `git rm PlaylistView.swift`, confirm Step 5 lifted everything still referenced: `EditBookmarkView` (moved), the `.timelineItemsIngested` observer (now in `ReaderFeedViewModel`, Task 4 Step 5), the DailyReview trigger (moved), and the TOC-zoom `model.selectedTab = .read` (line ~518 — already `.read`, just verify nothing else relies on `PlaylistView`). `grep -rn "PlaylistView" EchoCore Shared` must return zero non-test hits before deletion.

- [ ] **Step 7: Build**

```
make build-tests
```

Expected: build succeeds with no references to `.timeline`, `TimelineTab`, or `PlaylistView`. Re-run the Step 1 greps; expected: zero non-test hits for `\.timeline\b`, `TimelineTab`, `PlaylistView`.

- [ ] **Step 8: Run the full pure-logic suite**

```
make test-only FILTER=EchoTests/ReaderCardItemPhase2Tests
make test-only FILTER=EchoTests/OffStateResolverTests
make test-only FILTER=EchoTests/ReaderFeedDisplayBuilderPhase2Tests
```

Expected: all three suites pass (4 + 7 + 5 tests).

- [ ] **Step 9: Commit**

```
git add -A
git commit -m "refactor(feed): retire chronological playlist, collapse Read+Study into one tab, remap deep links"
```

---

## Task 7: Smoke build, doc-sync, PR

- [ ] **Step 1: Full build + the three new suites (single foreground run each; build slot must be free)**

```
make build-tests
make test-only FILTER=EchoTests/ReaderCardItemPhase2Tests
make test-only FILTER=EchoTests/OffStateResolverTests
make test-only FILTER=EchoTests/ReaderFeedDisplayBuilderPhase2Tests
```

Expected: build green; suites pass (16 tests total across the three).

- [ ] **Step 2: Doc-sync**

This phase removes a tab and a major view and changes the Study UX. Run the `doc-sync` skill, or update by hand:
- `ARCHITECTURE.md`: note Read+Study unified into one feed tab; chronological `PlaylistView`/`TimelineTab` retired; `OffStateResolver` reconciles `epub_block.is_hidden` (GRDB) with `.echoplaylist.json` track `enabled`.
- `CHANGELOG.md`: under the unreleased section — "Bookmarks and study cards now appear inline in the reading feed; per-chapter off-switch lives in a long-press menu; the separate Study tab is gone."
- `ROADMAP.md`: mark unified-feed Phase 2 done; Phase 3 (filters + sessions/GPS recap) next.

- [ ] **Step 3: Push + PR (target `nightly`)**

```
git push -u origin feature/unified-feed-phase2
gh pr create --base nightly \
  --title "feat(feed): Phase 2 — feed becomes the study surface" \
  --body "$(cat <<'EOF'
## Summary
Unified Feed Phase 2: the Read feed becomes the single Study surface.

- Bookmarks + Anki cards render inline, threaded into their chapter section in document order (new `ReaderCardItem` cases + `ReaderFeedDisplayBuilder.spliceExtras`).
- New `OffStateResolver` (Shared, pure) reconciles audio `isEnabled` (`.echoplaylist.json`) with EPUB `is_hidden` (GRDB) into one `ChapterOffState`; the feed reads one truth, the long-press menu writes the right flag(s) per heading kind.
- Per-chapter grey-out + a long-press context menu (Turn off everywhere + granular Listen / Narrate / Cards) — the ONLY place "off" lives.
- Retired the chronological Study/timeline playlist; collapsed Read + Study into one tab; remapped `.study` deep link to `.read`.
- `.nowPlaying` untouched. Swipe gesture (§13.3) intentionally NOT built.

## Tests
- `ReaderCardItemPhase2Tests` (4), `OffStateResolverTests` (7), `ReaderFeedDisplayBuilderPhase2Tests` (5). `make build-tests` green.

## Owner review flags (documented defaults in the plan)
- OffState write is best-effort across two stores (GRDB first, then manifest; no cross-system transaction).
- Narrate and Listen map to the same manifest `enabled` flag this phase.
- Per-chapter audio off falls back to all-tracks when no chapter→track map exists.
- Bookmark/card placement falls back to front-matter bucket when timestamp can't resolve.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 4: On-device verification handoff (owner)**

Build to a device with a synced book and confirm: bookmarks/cards appear inside the right chapter; long-press a chapter header → menu toggles work; an off chapter greys out and its cards/audio disappear; the Study tab is gone and `echo://study` deep links open the Read feed.

---

## Self-Review

**Spec coverage checklist (§5, §7.1, §7.2, §8, §12 Phase 2):**

- [ ] §8 — bookmarks + Anki cards as new `ReaderCardItem` cases, rendered inline via the Phase-1 cell registry (Tasks 1, 5).
- [ ] §8 — cards placed by `sourceBlockID`, fallback to `mediaTimestamp` (Task 4 `placement`).
- [ ] §7.1 — per-chapter grey-out (Task 5 Step 4, `ChapterOffState.isDimmed`).
- [ ] §7.1 — long-press context menu is the ONLY off control; Turn off everywhere + granular Listen/Narrate/Cards (Task 5 Step 6).
- [ ] §7.2 — one `OffStateResolver` reconciling audio `isEnabled` (PlaylistManifestService) vs `epub_block.is_hidden` (GRDB); reads one truth, writes correct flag per heading kind (Task 2, Task 4).
- [ ] §5 — retire the chronological Study/timeline playlist (Task 6, delete `TimelineTab`/`PlaylistView`).
- [ ] §5 — collapse Read + Study into one tab; remap deep links; `.nowPlaying` untouched (Task 6).
- [ ] §13.3 — swipe gesture reserved, NOT built (Open-question defaults).
- [ ] §12 Phase 2 — iOS only; pure types in `Shared/` for later macOS reuse (`OffStateResolver`).

**Type-consistency check:**

- `ReaderCardItem.id` for new cases: `"bm-\(id)"` / `"fc-\(id)"` — distinct from `"ch-…"`/`"b-…"` (Task 1 test `newCasesDoNotCollideWithExistingPrefixes`).
- `OffStateResolver.resolve` returns `ChapterOffState`; consumed by `ReaderFeedViewModel.chapterOffState` → `ReaderTab` closure → `ChapterDividerCell.configure(offState:)` — type flows end-to-end.
- `ReaderFeedDisplayBuilder.SplicedExtra.item: ReaderCardItem` matches the items the VM builds in `buildExtrasByChapter`.
- `BookmarkRecord`/`Flashcard` use synthesized memberwise inits in every fixture; field labels match `Shared/Database/BookmarkRecord.swift` / `Flashcard.swift`.
- `setChapterOff(_:on:chapterIndex:)` `OffKind` cases (`.all`/`.audio`/`.epub`) match the resolver write methods (`setAllOff`/`setAudioOff`/`setEpubOff`).
- All new `.swift` files start with the SPDX header on line 1 (verify after the SwiftFormat hook runs).

**Phase-1 dependency contract (must exist before Tasks 4–5):** `ReaderFeedViewModel.displaySections`, `openChapterKey`, `chapterHasAudio` (or `chaptersWithAudio`), `toggleChapter`; `ReaderFeedDisplayBuilder` (any grouping entry point); `FeedAccordion`; `ChapterDividerCell` with `configure(title:hasAudio:isExpanded:)` (the Phase-1 reshape of the bare `configure(with:)` cell); `ChapterAudioStatusResolver.chaptersWithAudio`. **As of Phase-1 SDD progress, only the pure types (`ReaderFeedDisplayBuilder`, `FeedAccordion`, `ChapterAudioStatusResolver`) are committed; the VM wiring and cell reshape are still pending.** Tasks 1–3 of this plan stand alone and can proceed; Tasks 4–5 are hard-gated on Phase-1 Tasks 4–5 landing first. If any Phase-1 name differs, only the call sites in Phase-2 Tasks 4–5 change.

---

## Execution Handoff

**Recommended — subagent-driven (superpowers:subagent-driven-development):** dispatch Tasks 1, 2, 3 in parallel (independent pure additions, no shared files). Then Task 4 (depends on 1+3), then Task 5 (depends on 1+2+4), then Task 6 (independent of 1–5 except it must build with them), then Task 7. Each subagent: implement its task's steps, run the exact commands, report the `#expect`/build output verbatim. The orchestrator runs **one** `xcodebuild`/`make` at a time (16 GB build-slot rule) — do not let two subagents build concurrently; serialize the build/test steps even when implementation is parallel.

**Inline alternative (superpowers:executing-plans):** work Tasks 1 → 7 in order in this session, committing after each. Same build-slot discipline: confirm the overnight harness is idle, run every `make` in the foreground with `timeout: 600000`, never two at once.
