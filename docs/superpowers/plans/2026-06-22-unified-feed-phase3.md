# Unified Feed — Phase 3 (Filters + Session Scope, iOS) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a two-dimensional filter to the unified reader feed. A **content-type axis** (Everything / Audio / Text / Pics / Pics+Audio / Bookmarks / Cards) filters the already-grouped `displaySections` via a pure predicate; a **scope axis** (Whole book / Last session) narrows the feed to a single listening session and surfaces a **recap card** atop the scoped feed (when, listened minutes, covered chapter range, item counts). All filter/scope decisions are pure value types in `Shared/`; the recap card's data is *derived at query time* from existing tables (`real_time_event` for the wall-clock window, `playback_event` for the covered book-position range and minutes) — no schema change, no denormalized cache.

**Architecture:** Add a pure `FeedFilter` value (content-type enum + scope enum) owned by `ReaderFeedViewModel`. The Phase-1 `ReaderFeedDisplayBuilder.displaySections(...)` output is post-filtered by a new pure `ReaderFeedDisplayBuilder.applyFilter(_:to:scopeWindow:)` inside the VM's `rebuildDisplaySections()`. Scope resolution (turning "Last session" into a concrete `started_at…ended_at` window plus a derived `coveredStart…coveredEnd` book-position range) is a GRDB struct `FeedScopeResolver { let db: DatabaseWriter }`, reusing the exact query shape already in `StatsRepository.fetchSegments`. A `SessionRecapViewModel` builds the recap card metadata. The chip row + scope selector live in `ReaderTab`; the collection view is a pass-through (no content-type logic moves into UIKit).

**Tech Stack:** Swift 6, SwiftUI + UIKit bridging (`UIViewRepresentable`), GRDB, Swift Testing (`@Test`/`#expect`), `DatabaseService(inMemory: ())`.

## Global Constraints

- **License header:** every new `.swift` file starts with `// SPDX-License-Identifier: GPL-3.0-or-later` on **line 1**. A SwiftFormat PostToolUse hook reflows imports on edit and can displace the SPDX header below an `import` — after editing, verify SPDX is still line 1 (a blank line after it detaches it from the import block).
- **Branch:** `feature/unified-feed-phase1`, cut from `origin/nightly` (PR #147 with the Phase-0 `ChapterAudioStatusResolver` is **already merged to nightly** — verified: merge commit `225e3eb`, resolver commit `cfe1d94` contained in `origin/nightly`). PRs target **`nightly`**, never `main`.
- **Scope is iOS only.** `ReaderFeedViewModel` / `ReaderFeedCollectionView` / `ReaderTab` import UIKit and are not in the macOS target. macOS parity is a later phase (spec §12). New **pure** types must stay UIKit-free so macOS can reuse them later: `FeedFilterModel` and `FeedScopeResolver` go in `Shared/`; `SessionRecapViewModel` and the `ReaderFeedDisplayBuilder+Filter` extension go in `EchoCore/` (UIKit-free, alongside the Phase-1 builder).
- **Build discipline (16 GB machine):** never run two `xcodebuild` invocations concurrently. The overnight `~/Developer/echo-overnight/redo-resume.sh` (NarrationHarness) holds the **exclusive** build slot — confirm it is idle/paused before any `make build-tests`. Run all builds in the **foreground** with a long timeout (`timeout: 600000`); a subagent that backgrounds a build yields unresumably. `make build-tests` and `make test-only` already pass `CODE_SIGNING_ALLOWED=NO` (Makefile `CODESIGN_OFF`); the sim destination is `iPhone 17`.
- **No schema change this phase (spec §9, §10).** Phase 3 reads only existing tables: `real_time_event`, `playback_event`, `timeline_item`, `epub_block`, `alignment_anchor`, `bookmark`. The covered position range is *derived*, not stored (verified §9 below) — a denormalized cache is added **only if** profiling shows reconstruction stalls smooth scroll, in which case claim the next-free migration (V24 on nightly — confirmed unclaimed) **at implementation time** and run the `schema-migration-reviewer` first. This plan ships with no migration.

---

## File Structure

**New files**

- `Shared/Services/FeedFilterModel.swift` *(create — `FeedContentType`, `FeedScope`, `FeedFilter`; pure, no UIKit/DB)*
- `Shared/Services/FeedScopeResolver.swift` *(create — `FeedScopeWindow` + `FeedScopeResolver { let db: DatabaseWriter }`; resolves a scope to a time window + derived position range)*
- `EchoCore/Models/ReaderFeedDisplayBuilder+Filter.swift` *(create — `static func applyFilter(_:to:chapterHasAudio:) -> [ReaderCardSection]`)*
- `EchoCore/ViewModels/SessionRecapViewModel.swift` *(create — recap card metadata: when, minutes, chapter range, counts)*
- `EchoTests/FeedFilterModelTests.swift` *(create — pure predicate tests)*
- `EchoTests/FeedScopeResolverTests.swift` *(create — DB-backed scope-derivation tests)*
- `EchoTests/ReaderFeedDisplayBuilderFilterTests.swift` *(create — pure filter-application tests)*
- `EchoTests/SessionRecapViewModelTests.swift` *(create — DB-backed recap-build tests)*

**Modified files**

- `EchoCore/ViewModels/ReaderFeedViewModel.swift` — add observed `var filter: FeedFilter`, `private(set) var scopeWindow: FeedScopeWindow?`, `private(set) var recap: SessionRecap?`; call `FeedScopeResolver` + `SessionRecapViewModel` on scope change; post-filter inside `rebuildDisplaySections()`; add `expandChapter(forSessionStart:)`.
- `EchoCore/Views/ReaderTab.swift` — add a filter chip row + scope selector above the feed; render the recap card; bind `vm.filter`.
- `EchoTests/ReaderFeedViewModelAccordionTests.swift` — append filter + scope tests (extend, do not replace).

**Responsibility boundaries**

- `FeedFilterModel` — *value only*: the two axes as `Equatable`/`Sendable` enums + struct. No data, no UIKit, no DB.
- `FeedScopeResolver` — *DB read only*: scope → concrete window + derived position range. One GRDB struct.
- `ReaderFeedDisplayBuilder+Filter` — *shape only*: post-filters a `[ReaderCardSection]` by content type. Pure.
- `SessionRecapViewModel` — *DB read only*: builds the recap metadata for the scoped window.
- `ReaderFeedViewModel` — *state + orchestration*: owns `filter`, calls the resolver/recap builder/pure filter, publishes `displaySections`/`recap`.
- `ReaderTab` — *rendering*: chip row, scope selector, recap card; routes selection back to `vm.filter`.

---

## Reference: load-bearing facts verified in the code

- **There is no `playback_session` table.** "Session" = two systems composed:
  1. `real_time_event` rows with `event_type = 'playback_session'` (`Shared/Database/Schema_V2.swift:36`) — coarse wall-clock window (`started_at`/`ended_at`), `title`/`subtitle`. **`audiobook_id` here is `folderURL.absoluteString`, NOT the GRDB `audiobook.id`.** Written by `PlaybackEventLogger` via `RealTimeEventDAO.log(...)`.
  2. `playback_event` rows with `event_type = 'play'` (`Shared/Database/Schema_V1.swift:99`) — fine-grained segments with `start_position`/`end_position` (book seconds), `started_at`/`ended_at`, `speed`. **`audiobook_id` here IS the GRDB UUID.** Written by `PlaybackSessionRecorder`.
- **Covered position range is derived, not stored.** `MIN(start_position)` / `MAX(end_position)` over the `playback_event` rows whose `started_at` falls in the session window. Indexed by `idx_playback_event_started_at` (`Schema_V14.swift:12`). 2–15 rows per session → cheap; no cache needed (spec §9).
- **`session_location` (`Schema_V14.swift:15`) has no write side** — nothing in the source tree inserts rows (confirmed). The recap "where" field is **deferred to Phase 5** (fork decision below); the card shows no location this phase.
- **The VM already holds the GRDB audiobook UUID**: `ReaderFeedViewModel.audiobookID: String` (`ReaderFeedViewModel.swift:15`) is the `audiobook.id` UUID used by `playback_event`. Phase 3 queries `playback_event` directly with this id for minutes/position range. `real_time_event` is queried only to find the *most-recent session's wall-clock window*; its rows are matched by **time ordering**, then intersected against `playback_event` by `started_at`, sidestepping the folder-URL-vs-UUID mismatch (Trap A) — we never JOIN the two tables on `audiobook_id`.
- `StatsRepository.fetchSegments(from:to:audiobookID:)` (`Shared/Stats/StatsRepository.swift:17`) is the exact query shape: `SELECT … FROM playback_event WHERE started_at >= ? AND started_at < ? AND ended_at IS NOT NULL AND event_type = 'play' [AND audiobook_id = ?]`. `FeedScopeResolver` reuses this shape with `<=` on the upper bound (sessions are closed ranges).
- `ListeningSegment` (`Shared/Stats/StatsModels.swift:26`): `startPosition`, `endPosition`, `speed`, `playbackDuration` (`max(0, endPosition - startPosition)`).
- `RealTimeEventRecord` (`Shared/Database/RealTimeEventRecord.swift:5`): `id`, `eventType`, `audiobookID?`, `startedAt`, `endedAt?`, `title?`, `subtitle?`, table `real_time_event`. `RealTimeEventDAO` (`Shared/Database/DAOs/RealTimeEventDAO.swift`): `log(...)`, `events(ofType:in:limit:)` (`:100`).
- `ReaderCardSection` (`EchoCore/Models/ReaderCardItem.swift:5`): `let id`, `let headingStack: [String]`, `let items: [ReaderCardItem]`. `id` = `"ch\(key)-s\(n)"`. `key` = audio chapter index (`block.chapterIndex ?? -1`; front matter → `-1`).
- `ReaderCardItem` (`EchoCore/Models/ReaderCardItem.swift:13`): `case chapterHeader(title:chapterIndex:)`, `case block(EPubBlockRecord)`. **No `.bookmark` / `.flashcard` case yet** — Phase 2 adds those (Trap D). Bookmarks/Cards chips ship **inactive/disabled** until Phase 2 merges.
- `EPubBlockRecord.Kind` (`Shared/Database/EPubBlockRecord.swift:61`): `.heading/.paragraph/.sentence/.image`, raw value `"image"`. Image discriminator is `blockKind == "image"` (Trap E), NOT `imagePath != nil`. `EPubBlockRecord` has a **synthesized memberwise init** — use it in fixtures; it exposes `chapterIndex: Int?`.
- Phase-1 VM additions (`displaySections: [ReaderCardSection]`, `chapterHasAudio: [Int: Bool]`, `openChapterKey: Int?`, `toggleChapter(_:)`, `expandChapter(containingBlockID:)`, `rebuildDisplaySections()`) are **not yet committed** as of the critique gate (Phase-1 Task 4 is `in_progress`, accordion test file is untracked). **Phase 3 Tasks 3, 5, and 6 must not be started until Phase-1 Task 4 is committed.** Phase 3 inserts the filter pass inside `rebuildDisplaySections()` once it exists.
- Test conventions: Swift Testing `@Test`/`#expect`, `@testable import Echo`, `DatabaseService(inMemory: ())` then `db.writer` / `db.write { db in … }`. GRDB DAOs are `struct X { let db: DatabaseWriter }`.

---

## Forks / open questions (best-judgment defaults — flagged for owner review)

1. **GPS in the recap card (Trap C).** `session_location` is inert (no writer). **Default: DEFER GPS to Phase 5.** The recap card omits "where" this phase; `SessionRecap` has no location field. Building the opt-in Core Location writer is out of scope and matches the spec's "opt-in" language. *Owner: confirm GPS waits for Phase 5.*
2. **Bookmarks/Cards chip granularity (spec §13.5, Trap I).** **Default: individual chips for Bookmarks and Cards** (not a "Marks" group) — the spec lists them separately and a sub-menu is heavier UI than two chips. *Owner: confirm two chips vs. a group.*
3. **Bookmarks/Cards chips before Phase 2 (Trap D).** `ReaderCardItem` has no bookmark/card case yet. **Default: render the Bookmarks and Cards chips but disabled (greyed, non-selectable) until Phase 2 merges**, so the chip bar's final shape is locked now and Phase 2 only flips them live. The `FeedContentType` enum includes `.bookmarks`/`.cards` cases now; the predicate for them is a no-op pass-through until the cases exist (documented in code). *Owner: confirm ship-disabled.*
4. **"Text" filter meaning (Trap F2).** **Default: "Text" = chapters without audio** (`chapterHasAudio[key] == false`), i.e. text-only / narratable chapters. *Owner: confirm.*
5. **"Audio" filter granularity (Trap F).** Chapter-level: keep chapter groups where `chapterHasAudio[key] == true`. Not per-block.
6. **Scope axis this phase.** Spec §6 lists "Sessions…" (a full session picker) as a later surface. **Default: ship `wholeBook` + `lastSession` only** (plus the `session(id:…)` enum case wired for a future picker, unused by UI this phase). *Owner: confirm the picker is deferred.*

---

## Task 1: Filter value types (`FeedFilterModel`)

Pure, UIKit-free value types for the two axes. Lives in `Shared/` so macOS reuses it later.

**Files:**
- Create: `Shared/Services/FeedFilterModel.swift`
- Test: `EchoTests/FeedFilterModelTests.swift`

**Interfaces:**
- Produces: `enum FeedContentType: String, CaseIterable, Sendable`, `enum FeedScope: Equatable, Sendable`, `struct FeedFilter: Equatable, Sendable`.
- Produces: `FeedContentType.matchesChapter(hasAudio:)` and `FeedContentType.matchesBlockKind(_:hasAudio:)` pure predicates used by the Task 3 filter.

- [ ] **Step 1: Write the failing test**

Create `EchoTests/FeedFilterModelTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import Echo

@Suite struct FeedFilterModelTests {

    @Test func everythingMatchesEveryChapter() {
        #expect(FeedContentType.everything.matchesChapter(hasAudio: true))
        #expect(FeedContentType.everything.matchesChapter(hasAudio: false))
    }

    @Test func audioMatchesOnlyChaptersWithAudio() {
        #expect(FeedContentType.audio.matchesChapter(hasAudio: true))
        #expect(!FeedContentType.audio.matchesChapter(hasAudio: false))
    }

    @Test func textMatchesOnlyChaptersWithoutAudio() {
        #expect(!FeedContentType.text.matchesChapter(hasAudio: true))
        #expect(FeedContentType.text.matchesChapter(hasAudio: false))
    }

    @Test func chapterLevelFiltersAcceptWholeChapter() {
        // Pics / Pics+Audio / Bookmarks / Cards do NOT drop whole chapters;
        // they filter at the block level (matchesChapter is always true so the
        // group survives to be item-filtered).
        for t in [FeedContentType.pics, .picsAndAudio, .bookmarks, .cards] {
            #expect(t.matchesChapter(hasAudio: true))
            #expect(t.matchesChapter(hasAudio: false))
        }
    }

    @Test func picsMatchesOnlyImageBlocks() {
        #expect(FeedContentType.pics.matchesBlockKind("image", hasAudio: false))
        #expect(!FeedContentType.pics.matchesBlockKind("paragraph", hasAudio: false))
        #expect(!FeedContentType.pics.matchesBlockKind("heading", hasAudio: true))
    }

    @Test func picsAndAudioMatchesImageBlocksInAudioChapters() {
        #expect(FeedContentType.picsAndAudio.matchesBlockKind("image", hasAudio: true))
        #expect(!FeedContentType.picsAndAudio.matchesBlockKind("image", hasAudio: false))
        #expect(!FeedContentType.picsAndAudio.matchesBlockKind("paragraph", hasAudio: true))
    }

    @Test func everythingMatchesEveryBlock() {
        #expect(FeedContentType.everything.matchesBlockKind("paragraph", hasAudio: false))
        #expect(FeedContentType.everything.matchesBlockKind("image", hasAudio: true))
    }

    @Test func audioAndTextDoNotItemFilter() {
        // Audio/Text are chapter-level only; once a chapter survives, every block in it stays.
        for t in [FeedContentType.audio, .text] {
            #expect(t.matchesBlockKind("paragraph", hasAudio: true))
            #expect(t.matchesBlockKind("image", hasAudio: false))
        }
    }

    @Test func defaultFilterIsEverythingWholeBook() {
        let f = FeedFilter()
        #expect(f.contentType == .everything)
        #expect(f.scope == .wholeBook)
    }

    @Test func filterEquatableByBothAxes() {
        #expect(FeedFilter(contentType: .audio, scope: .wholeBook)
                == FeedFilter(contentType: .audio, scope: .wholeBook))
        #expect(FeedFilter(contentType: .audio, scope: .wholeBook)
                != FeedFilter(contentType: .text, scope: .wholeBook))
        #expect(FeedFilter(contentType: .audio, scope: .wholeBook)
                != FeedFilter(contentType: .audio, scope: .lastSession))
    }

    @Test func allContentTypesAreEnumerable() {
        // Drives the chip row; assert the full set so a new case forces a chip update.
        #expect(FeedContentType.allCases == [
            .everything, .audio, .text, .pics, .picsAndAudio, .bookmarks, .cards
        ])
    }
}
```

Run it (expect: does-not-compile — `FeedFilter*` undefined):

```
make build-tests
```

Expected: compile error `cannot find 'FeedContentType' in scope`.

- [ ] **Step 2: Implement `FeedFilterModel`**

Create `Shared/Services/FeedFilterModel.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Content-type axis of the unified-feed filter. Pure value type; no UIKit, no DB.
///
/// `matchesChapter` decides whether a whole chapter GROUP survives (Audio/Text are
/// chapter-granular per Phase-3 Trap F/F2). `matchesBlockKind` decides whether an
/// individual block survives inside a surviving group (Pics/Pics+Audio are block-granular
/// per Trap E). `.bookmarks` / `.cards` are placeholders until Phase 2 adds the
/// corresponding `ReaderCardItem` cases — their predicates are pass-throughs today.
public enum FeedContentType: String, CaseIterable, Sendable {
    case everything
    case audio
    case text
    case pics
    case picsAndAudio
    case bookmarks
    case cards

    /// Whether a chapter group with the given has-audio flag survives this filter.
    /// Chapter-level filters (audio/text) drop whole groups; block-level filters
    /// (pics/picsAndAudio/bookmarks/cards) keep every group and filter items instead.
    public func matchesChapter(hasAudio: Bool) -> Bool {
        switch self {
        case .everything: return true
        case .audio: return hasAudio
        case .text: return !hasAudio
        case .pics, .picsAndAudio, .bookmarks, .cards: return true
        }
    }

    /// Whether an individual block of the given kind, in a chapter with the given
    /// has-audio flag, survives this filter. Chapter-level filters keep every block
    /// in a surviving group. `EPubBlockRecord.Kind.image.rawValue == "image"`.
    public func matchesBlockKind(_ blockKind: String, hasAudio: Bool) -> Bool {
        switch self {
        case .everything, .audio, .text:
            return true
        case .pics:
            return blockKind == "image"
        case .picsAndAudio:
            return blockKind == "image" && hasAudio
        case .bookmarks, .cards:
            // Phase 2 adds bookmark/card ReaderCardItem cases; until then these chips
            // ship disabled and never reach here. Pass-through keeps the group intact.
            return true
        }
    }

    /// True when this filter narrows individual blocks within a surviving group.
    /// Chapter-level filters (everything/audio/text) do not item-filter.
    public var isBlockLevel: Bool {
        switch self {
        case .everything, .audio, .text: return false
        case .pics, .picsAndAudio, .bookmarks, .cards: return true
        }
    }
}

/// Scope axis of the unified-feed filter. `lastSession` is resolved to a concrete
/// `session(id:startedAt:endedAt:)` by `FeedScopeResolver`; the explicit case is kept
/// for a future session picker (spec §6 "Sessions…", deferred this phase).
public enum FeedScope: Equatable, Sendable {
    case wholeBook
    case lastSession
    case session(id: String, startedAt: Date, endedAt: Date)
}

/// The two-dimensional unified-feed filter.
public struct FeedFilter: Equatable, Sendable {
    public var contentType: FeedContentType
    public var scope: FeedScope

    public init(contentType: FeedContentType = .everything, scope: FeedScope = .wholeBook) {
        self.contentType = contentType
        self.scope = scope
    }
}
```

- [ ] **Step 3: Run the test**

```
make build-tests
make test-only FILTER=EchoTests/FeedFilterModelTests
```

Expected: `Test Suite 'FeedFilterModelTests' passed` — 11 tests, 0 failures.

- [ ] **Step 4: Commit**

```
git add Shared/Services/FeedFilterModel.swift EchoTests/FeedFilterModelTests.swift
git commit -m "feat(feed): add FeedFilter two-axis value types (content-type + scope)"
```

---

## Task 2: Scope resolver (`FeedScopeResolver`)

Turns a `FeedScope` into a concrete `FeedScopeWindow` (wall-clock window + derived book-position range), reading `real_time_event` for the window and `playback_event` for the range. Avoids the folder-URL-vs-UUID mismatch (Trap A) by matching `real_time_event` rows by recency, then intersecting `playback_event` (queried by the GRDB `audiobook.id`) on `started_at`.

**Files:**
- Create: `Shared/Services/FeedScopeResolver.swift`
- Test: `EchoTests/FeedScopeResolverTests.swift`

**Interfaces:**
- Consumes: `playback_event` (`event_type='play'`, `ended_at IS NOT NULL`, indexed `started_at`), `real_time_event` (`event_type='playback_session'`).
- Produces: `struct FeedScopeWindow: Equatable, Sendable { startedAt, endedAt, coveredStartPosition, coveredEndPosition, listenedSeconds }`.
- Produces: `struct FeedScopeResolver { let db: DatabaseWriter; func lastSessionWindow(audiobookID:) throws -> FeedScopeWindow?; func sessionWindow(id:audiobookID:) throws -> FeedScopeWindow? }`.

- [ ] **Step 1: Write the failing test**

Create `EchoTests/FeedScopeResolverTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
import Foundation
import GRDB
@testable import Echo

@Suite struct FeedScopeResolverTests {

    private let iso = ISO8601DateFormatter()

    /// Inserts the audiobook row + one playback_event 'play' segment.
    private func insertPlay(
        _ db: Database,
        audiobookID: String,
        startedAt: Date,
        endedAt: Date,
        startPosition: Double,
        endPosition: Double,
        speed: Double = 1.0
    ) throws {
        try db.execute(sql: """
            INSERT INTO playback_event
              (audiobook_id, track_id, started_at, ended_at,
               start_position, end_position, speed, event_type, source)
            VALUES (?, NULL, ?, ?, ?, ?, ?, 'play', 'test')
            """, arguments: [audiobookID, iso.string(from: startedAt),
                             iso.string(from: endedAt), startPosition, endPosition, speed])
    }

    private func insertSessionMarker(
        _ db: Database,
        id: String,
        folderURL: String,
        startedAt: Date,
        endedAt: Date?
    ) throws {
        try db.execute(sql: """
            INSERT INTO real_time_event
              (id, event_type, audiobook_id, media_timestamp, started_at, ended_at,
               title, subtitle, metadata_json, source_item_id, source_item_type)
            VALUES (?, 'playback_session', ?, NULL, ?, ?, 'Chapter 1', 'My Book',
                    NULL, NULL, NULL)
            """, arguments: [id, folderURL, iso.string(from: startedAt),
                             endedAt.map { iso.string(from: $0) }])
    }

    private func makeBook(_ db: Database, id: String) throws {
        try db.execute(sql: """
            INSERT INTO audiobook (id, title, author, duration, added_at)
            VALUES (?, 'My Book', 'Author', 3600, ?)
            """, arguments: [id, iso.string(from: Date())])
    }

    @Test func lastSessionDerivesWindowAndCoveredRange() throws {
        let db = try DatabaseService(inMemory: ())
        let bookID = "BOOK-UUID"
        let folder = "file:///Books/My%20Book/"
        let base = iso.date(from: "2026-06-22T10:00:00Z")!

        try db.writer.write { db in
            try makeBook(db, id: bookID)
            // Coarse session marker: 10:00 -> 10:30.
            try insertSessionMarker(db, id: "S1", folderURL: folder,
                                    startedAt: base, endedAt: base.addingTimeInterval(1800))
            // Two play segments inside the window.
            try insertPlay(db, audiobookID: bookID,
                           startedAt: base.addingTimeInterval(60),
                           endedAt: base.addingTimeInterval(660),
                           startPosition: 120, endPosition: 720, speed: 1.0)
            try insertPlay(db, audiobookID: bookID,
                           startedAt: base.addingTimeInterval(900),
                           endedAt: base.addingTimeInterval(1500),
                           startPosition: 700, endPosition: 1300, speed: 2.0)
            // A segment from a DIFFERENT, earlier session — must be excluded.
            try insertPlay(db, audiobookID: bookID,
                           startedAt: base.addingTimeInterval(-7200),
                           endedAt: base.addingTimeInterval(-6600),
                           startPosition: 0, endPosition: 50, speed: 1.0)
        }

        let resolver = FeedScopeResolver(db: db.writer)
        let window = try #require(try resolver.lastSessionWindow(audiobookID: bookID))

        #expect(window.startedAt == base)
        #expect(window.endedAt == base.addingTimeInterval(1800))
        // covered range = min(start)…max(end) over the two in-window segments.
        #expect(window.coveredStartPosition == 120)
        #expect(window.coveredEndPosition == 1300)
        // listened seconds = sum((end-start)/speed) = 600/1 + 600/2 = 900.
        #expect(window.listenedSeconds == 900)
    }

    @Test func lastSessionReturnsNilWhenNoSessionMarker() throws {
        let db = try DatabaseService(inMemory: ())
        try db.writer.write { db in try makeBook(db, id: "B") }
        let resolver = FeedScopeResolver(db: db.writer)
        #expect(try resolver.lastSessionWindow(audiobookID: "B") == nil)
    }

    @Test func openSessionUsesNowAsUpperBound() throws {
        let db = try DatabaseService(inMemory: ())
        let bookID = "B"
        let base = Date().addingTimeInterval(-600)
        try db.writer.write { db in
            try makeBook(db, id: bookID)
            // ended_at NULL = still open.
            try insertSessionMarker(db, id: "S", folderURL: "file:///x/",
                                    startedAt: base, endedAt: nil)
            try insertPlay(db, audiobookID: bookID,
                           startedAt: base.addingTimeInterval(10),
                           endedAt: base.addingTimeInterval(310),
                           startPosition: 30, endPosition: 330)
        }
        let resolver = FeedScopeResolver(db: db.writer)
        let window = try #require(try resolver.lastSessionWindow(audiobookID: bookID))
        #expect(window.coveredStartPosition == 30)
        #expect(window.coveredEndPosition == 330)
        // endedAt defaulted to ~now (>= the play segment's end).
        #expect(window.endedAt >= base.addingTimeInterval(310))
    }

    @Test func lastSessionWithMarkerButNoPlaysHasZeroRange() throws {
        let db = try DatabaseService(inMemory: ())
        let bookID = "B"
        let base = iso.date(from: "2026-06-22T08:00:00Z")!
        try db.writer.write { db in
            try makeBook(db, id: bookID)
            try insertSessionMarker(db, id: "S", folderURL: "file:///x/",
                                    startedAt: base, endedAt: base.addingTimeInterval(60))
        }
        let resolver = FeedScopeResolver(db: db.writer)
        let window = try #require(try resolver.lastSessionWindow(audiobookID: bookID))
        #expect(window.coveredStartPosition == 0)
        #expect(window.coveredEndPosition == 0)
        #expect(window.listenedSeconds == 0)
    }

    @Test func sessionWindowByIDResolvesNamedSession() throws {
        let db = try DatabaseService(inMemory: ())
        let bookID = "B"
        let base = iso.date(from: "2026-06-22T09:00:00Z")!
        try db.writer.write { db in
            try makeBook(db, id: bookID)
            try insertSessionMarker(db, id: "TARGET", folderURL: "file:///x/",
                                    startedAt: base, endedAt: base.addingTimeInterval(600))
            try insertPlay(db, audiobookID: bookID,
                           startedAt: base.addingTimeInterval(30),
                           endedAt: base.addingTimeInterval(330),
                           startPosition: 200, endPosition: 500)
        }
        let resolver = FeedScopeResolver(db: db.writer)
        let window = try #require(try resolver.sessionWindow(id: "TARGET", audiobookID: bookID))
        #expect(window.startedAt == base)
        #expect(window.coveredStartPosition == 200)
        #expect(window.coveredEndPosition == 500)
    }
}
```

Run it (expect: does-not-compile):

```
make build-tests
```

Expected: compile error `cannot find 'FeedScopeResolver' in scope`.

- [ ] **Step 2: Implement `FeedScopeResolver`**

Create `Shared/Services/FeedScopeResolver.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

/// A resolved scope: a wall-clock window plus the book-position range it covered.
/// `coveredStartPosition`/`coveredEndPosition` are book seconds derived from
/// `playback_event` rows inside the window. `listenedSeconds` is wall-clock listening
/// time (segment span ÷ speed) summed across those rows.
public struct FeedScopeWindow: Equatable, Sendable {
    public let startedAt: Date
    public let endedAt: Date
    public let coveredStartPosition: TimeInterval
    public let coveredEndPosition: TimeInterval
    public let listenedSeconds: TimeInterval

    public init(
        startedAt: Date,
        endedAt: Date,
        coveredStartPosition: TimeInterval,
        coveredEndPosition: TimeInterval,
        listenedSeconds: TimeInterval
    ) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.coveredStartPosition = coveredStartPosition
        self.coveredEndPosition = coveredEndPosition
        self.listenedSeconds = listenedSeconds
    }
}

/// Resolves a `FeedScope` to a concrete `FeedScopeWindow`.
///
/// "Session" is two systems (no `playback_session` table): the coarse
/// `real_time_event` (`event_type='playback_session'`) gives the wall-clock window;
/// `playback_event` (`event_type='play'`) gives the covered book-position range and
/// listened minutes. We do NOT join the two tables on `audiobook_id` — `real_time_event`
/// stores a folder URL there while `playback_event` stores the GRDB UUID — instead we
/// find the latest session marker by recency, then intersect `playback_event` (queried
/// by the GRDB `audiobook.id`) on `started_at` within that window.
public struct FeedScopeResolver {
    public let db: DatabaseWriter

    public init(db: DatabaseWriter) {
        self.db = db
    }

    private static let iso = ISO8601DateFormatter()

    /// The most recent `playback_session` marker's window, with the covered range
    /// derived from `playback_event` rows inside it. Returns nil if no marker exists.
    public func lastSessionWindow(audiobookID: String) throws -> FeedScopeWindow? {
        try db.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT started_at, ended_at
                FROM real_time_event
                WHERE event_type = 'playback_session'
                ORDER BY started_at DESC
                LIMIT 1
                """) else { return nil }
            return try Self.window(db: db, audiobookID: audiobookID, markerRow: row)
        }
    }

    /// A specific session marker's window (for a future session picker). Returns nil
    /// if no marker with that id exists.
    public func sessionWindow(id: String, audiobookID: String) throws -> FeedScopeWindow? {
        try db.read { db in
            guard let row = try Row.fetchOne(db, sql: """
                SELECT started_at, ended_at
                FROM real_time_event
                WHERE event_type = 'playback_session' AND id = ?
                LIMIT 1
                """, arguments: [id]) else { return nil }
            return try Self.window(db: db, audiobookID: audiobookID, markerRow: row)
        }
    }

    /// Builds a window from a marker row + the in-window `playback_event` aggregation.
    private static func window(
        db: Database,
        audiobookID: String,
        markerRow: Row
    ) throws -> FeedScopeWindow? {
        guard let startedAtStr: String = markerRow["started_at"],
              let startedAt = iso.date(from: startedAtStr) else { return nil }
        // Open session → upper bound is now.
        let endedAt: Date
        if let endedAtStr: String = markerRow["ended_at"], let d = iso.date(from: endedAtStr) {
            endedAt = d
        } else {
            endedAt = Date()
        }

        let startStr = iso.string(from: startedAt)
        let endStr = iso.string(from: endedAt)

        // Covered position range + listened seconds over in-window play segments.
        // Closed range on started_at (sessions are inclusive at both ends).
        let agg = try Row.fetchOne(db, sql: """
            SELECT MIN(start_position) AS min_pos,
                   MAX(end_position)   AS max_pos,
                   SUM((end_position - start_position) / speed) AS listened
            FROM playback_event
            WHERE audiobook_id = ?
              AND event_type = 'play'
              AND ended_at IS NOT NULL
              AND started_at >= ?
              AND started_at <= ?
            """, arguments: [audiobookID, startStr, endStr])

        let minPos: Double = agg?["min_pos"] ?? 0
        let maxPos: Double = agg?["max_pos"] ?? 0
        let listened: Double = agg?["listened"] ?? 0

        return FeedScopeWindow(
            startedAt: startedAt,
            endedAt: endedAt,
            coveredStartPosition: minPos,
            coveredEndPosition: maxPos,
            listenedSeconds: max(0, listened)
        )
    }
}
```

- [ ] **Step 3: Run the test**

```
make build-tests
make test-only FILTER=EchoTests/FeedScopeResolverTests
```

Expected: `Test Suite 'FeedScopeResolverTests' passed` — 5 tests, 0 failures.

- [ ] **Step 4: Commit**

```
git add Shared/Services/FeedScopeResolver.swift EchoTests/FeedScopeResolverTests.swift
git commit -m "feat(feed): add FeedScopeResolver (last-session window + derived covered range)"
```

---

## Task 3: Pure content-type filter (`ReaderFeedDisplayBuilder+Filter`)

Post-filters the Phase-1 `displaySections` output by content type. Drops whole chapter groups for chapter-level filters (Audio/Text); strips non-matching blocks inside surviving groups for block-level filters (Pics/Pics+Audio). Pure — no DB, no UIKit.

**Files:**
- Create: `EchoCore/Models/ReaderFeedDisplayBuilder+Filter.swift`
- Test: `EchoTests/ReaderFeedDisplayBuilderFilterTests.swift`

**Interfaces:**
- Consumes: `[ReaderCardSection]` (already grouped/accordion-applied by Phase 1), `chapterHasAudio: [Int: Bool]`.
- Produces: `static func applyFilter(_ contentType: FeedContentType, to sections: [ReaderCardSection], chapterHasAudio: [Int: Bool]) -> [ReaderCardSection]`.

- [ ] **Step 1: Write the failing test**

Create `EchoTests/ReaderFeedDisplayBuilderFilterTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
@testable import Echo

@Suite struct ReaderFeedDisplayBuilderFilterTests {

    // MARK: fixtures

    /// Minimal EPubBlockRecord via the synthesized memberwise init.
    /// Property order matches EPubBlockRecord.swift:8-30 (D2 fix — use full memberwise init).
    private func block(
        id: String,
        chapterIndex: Int?,
        kind: String,
        text: String? = "x",
        imagePath: String? = nil
    ) -> EPubBlockRecord {
        EPubBlockRecord(
            id: id,
            audiobookID: "B",
            spineHref: "spine.xhtml",
            spineIndex: 0,
            blockIndex: 0,
            sequenceIndex: 0,
            blockKind: kind,
            text: text,
            htmlContent: nil,
            cardColor: nil,
            chapterThemeColor: nil,
            imagePath: imagePath,
            chapterIndex: chapterIndex,
            isHidden: false,
            hiddenReason: nil,
            isFrontMatter: false,
            wordCount: nil,
            markers: nil,
            textFormats: nil,
            createdAt: nil,
            modifiedAt: nil
        )
    }

    private func section(key: Int, items: [ReaderCardItem]) -> ReaderCardSection {
        ReaderCardSection(id: "ch\(key)-s0", headingStack: ["H"], items: items)
    }

    /// Two chapters: chapter 0 (audio) with a heading + paragraph + image;
    /// chapter 1 (no audio) with a heading + paragraph.
    private func sampleSections() -> [ReaderCardSection] {
        [
            section(key: 0, items: [
                .chapterHeader(title: "Ch1", chapterIndex: 0),
                .block(block(id: "b0", chapterIndex: 0, kind: "paragraph")),
                .block(block(id: "b1", chapterIndex: 0, kind: "image", text: nil, imagePath: "p.jpg"))
            ]),
            section(key: 1, items: [
                .chapterHeader(title: "Ch2", chapterIndex: 1),
                .block(block(id: "b2", chapterIndex: 1, kind: "paragraph"))
            ])
        ]
    }

    private let hasAudio: [Int: Bool] = [0: true, 1: false]

    private func ids(_ sections: [ReaderCardSection]) -> [String] {
        sections.flatMap { $0.items.map(\.id) }
    }

    @Test func everythingIsIdentity() {
        let out = ReaderFeedDisplayBuilder.applyFilter(.everything, to: sampleSections(), chapterHasAudio: hasAudio)
        #expect(ids(out) == ["ch-0", "b-b0", "b-b1", "ch-1", "b-b2"])
    }

    @Test func audioKeepsOnlyAudioChapterGroups() {
        let out = ReaderFeedDisplayBuilder.applyFilter(.audio, to: sampleSections(), chapterHasAudio: hasAudio)
        // Chapter 1 (no audio) dropped entirely; chapter 0 fully retained.
        #expect(ids(out) == ["ch-0", "b-b0", "b-b1"])
    }

    @Test func textKeepsOnlyNoAudioChapterGroups() {
        let out = ReaderFeedDisplayBuilder.applyFilter(.text, to: sampleSections(), chapterHasAudio: hasAudio)
        #expect(ids(out) == ["ch-1", "b-b2"])
    }

    @Test func picsKeepsHeadersPlusImageBlocksOnly() {
        let out = ReaderFeedDisplayBuilder.applyFilter(.pics, to: sampleSections(), chapterHasAudio: hasAudio)
        // Headers always survive (so the TOC structure stays); only image blocks remain.
        // Chapter 1 has no images → header survives but is emptied of blocks, and a
        // group with only a header is dropped (no content to show under Pics).
        #expect(ids(out) == ["ch-0", "b-b1"])
    }

    @Test func picsAndAudioKeepsImagesInAudioChaptersOnly() {
        // Image b1 is in chapter 0 (audio) → kept. No images in chapter 1.
        let out = ReaderFeedDisplayBuilder.applyFilter(.picsAndAudio, to: sampleSections(), chapterHasAudio: hasAudio)
        #expect(ids(out) == ["ch-0", "b-b1"])
    }

    @Test func picsAndAudioDropsImageInNonAudioChapter() {
        var sections = sampleSections()
        // Add an image to chapter 1 (no audio); it must NOT survive picsAndAudio.
        sections[1] = section(key: 1, items: [
            .chapterHeader(title: "Ch2", chapterIndex: 1),
            .block(block(id: "b2", chapterIndex: 1, kind: "paragraph")),
            .block(block(id: "b3", chapterIndex: 1, kind: "image", text: nil, imagePath: "q.jpg"))
        ])
        let out = ReaderFeedDisplayBuilder.applyFilter(.picsAndAudio, to: sections, chapterHasAudio: hasAudio)
        #expect(ids(out) == ["ch-0", "b-b1"])
    }

    @Test func bookmarksChipIsPassThroughUntilPhase2() {
        // No bookmark ReaderCardItem case yet → predicate is a no-op; nothing removed.
        let out = ReaderFeedDisplayBuilder.applyFilter(.bookmarks, to: sampleSections(), chapterHasAudio: hasAudio)
        #expect(ids(out) == ["ch-0", "b-b0", "b-b1", "ch-1", "b-b2"])
    }

    @Test func emptyInputYieldsEmpty() {
        let out = ReaderFeedDisplayBuilder.applyFilter(.audio, to: [], chapterHasAudio: hasAudio)
        #expect(out.isEmpty)
    }
}
```

> **NOTE on fixture init (D2):** the `EPubBlockRecord(...)` argument list above was verified against `Shared/Database/EPubBlockRecord.swift:8-30` and includes all required properties (`spineHref`, `spineIndex`, `blockIndex`, `isHidden`, etc.). Earlier plan drafts used a non-existent `alignmentStatus:`/`audioStartTime:` that do not exist on this type — those were removed.

Run it (expect: does-not-compile):

```
make build-tests
```

Expected: compile error `type 'ReaderFeedDisplayBuilder' has no member 'applyFilter'`.

- [ ] **Step 2: Implement the filter extension**

Create `EchoCore/Models/ReaderFeedDisplayBuilder+Filter.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

extension ReaderFeedDisplayBuilder {

    /// Post-filters the Phase-1 grouped/accordion display sections by content type.
    ///
    /// Two granularities (Phase-3 Traps E/F/F2):
    /// - Chapter-level (`.audio`/`.text`): drop whole chapter GROUPS whose has-audio
    ///   flag doesn't match.
    /// - Block-level (`.pics`/`.picsAndAudio`): keep the chapter header but strip
    ///   non-matching blocks; a group left with only a header (no content blocks) is
    ///   dropped, since there's nothing to show under that filter.
    /// `.everything` is the identity. `.bookmarks`/`.cards` are pass-throughs until
    /// Phase 2 adds the matching `ReaderCardItem` cases.
    ///
    /// `chapterHasAudio` keys are audio chapter indices (`block.chapterIndex ?? -1`);
    /// front matter is `-1`. A missing key is treated as no-audio.
    public static func applyFilter(
        _ contentType: FeedContentType,
        to sections: [ReaderCardSection],
        chapterHasAudio: [Int: Bool]
    ) -> [ReaderCardSection] {
        guard contentType != .everything else { return sections }

        // Chapter-level: drop or keep whole groups by the section's chapter key.
        // Real API: chapterKey(forSectionID:) -> Int? (ReaderFeedDisplayBuilder.swift:25)
        if !contentType.isBlockLevel {
            return sections.filter { section in
                let key = chapterKey(forSectionID: section.id) ?? -1
                let audio = chapterHasAudio[key] ?? false
                return contentType.matchesChapter(hasAudio: audio)
            }
        }

        // Block-level: keep header, strip non-matching blocks, drop content-empty groups.
        var result: [ReaderCardSection] = []
        for section in sections {
            let key = chapterKey(forSectionID: section.id) ?? -1
            let audio = chapterHasAudio[key] ?? false

            var kept: [ReaderCardItem] = []
            var contentBlockCount = 0
            for item in section.items {
                switch item {
                case .chapterHeader:
                    kept.append(item) // headers always survive (TOC structure)
                case let .block(block):
                    if contentType.matchesBlockKind(block.blockKind, hasAudio: audio) {
                        kept.append(item)
                        contentBlockCount += 1
                    }
                }
            }

            // A surviving group must have at least one content block under this filter;
            // a header-only group is noise and gets dropped.
            if contentBlockCount > 0 {
                result.append(ReaderCardSection(
                    id: section.id,
                    headingStack: section.headingStack,
                    items: kept
                ))
            }
        }
        return result
    }

    /// The audio chapter key for a section: the chapterIndex of its first `.block`
    /// item, or the `.chapterHeader`'s chapterIndex, else `-1` (front matter).
    /// Mirrors the Phase-1 key derivation (`block.chapterIndex ?? -1`).
    // NOTE: do NOT add a chapterKey(forSection:) overload here.
    // The real API is chapterKey(forSectionID id: String) -> Int? on ReaderFeedDisplayBuilder
    // (ReaderFeedDisplayBuilder.swift:25). The internal calls above use that real API.
}
```

> **NOTE:** the real API is `chapterKey(forSectionID id: String) -> Int?` (`ReaderFeedDisplayBuilder.swift:25`). All calls above use `chapterKey(forSectionID: section.id) ?? -1`. Do NOT add a `chapterKey(forSection:)` overload — the real one takes a section id string, not a `ReaderCardSection` value. The plan's earlier draft invented a different signature that does not compile against the real type.

- [ ] **Step 3: Run the test**

```
make build-tests
make test-only FILTER=EchoTests/ReaderFeedDisplayBuilderFilterTests
```

Expected: `Test Suite 'ReaderFeedDisplayBuilderFilterTests' passed` — 8 tests, 0 failures.

- [ ] **Step 4: Commit**

```
git add EchoCore/Models/ReaderFeedDisplayBuilder+Filter.swift EchoTests/ReaderFeedDisplayBuilderFilterTests.swift
git commit -m "feat(feed): add pure content-type filter (applyFilter) over display sections"
```

---

## Task 4: Session recap builder (`SessionRecapViewModel`)

Builds the recap card metadata for a scoped window: when, listened minutes, covered chapter range, and item counts (bookmarks/cards created in the window). All derived at query time. GPS is deferred (fork 1).

**Files:**
- Create: `EchoCore/ViewModels/SessionRecapViewModel.swift`
- Test: `EchoTests/SessionRecapViewModelTests.swift`

**Interfaces:**
- Consumes: a `FeedScopeWindow` + `audiobookID`; reads `timeline_item`+`epub_block` (chapter range) and `bookmark` (item counts).
- Produces: `struct SessionRecap: Equatable, Sendable { startedAt, listenedSeconds, coveredChapterIndices: [Int], bookmarkCount, cardCount }` and `struct SessionRecapViewModel { let db: DatabaseWriter; func recap(audiobookID:window:) throws -> SessionRecap }`.

- [ ] **Step 1: Write the failing test**

Create `EchoTests/SessionRecapViewModelTests.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Testing
import Foundation
import GRDB
@testable import Echo

@Suite struct SessionRecapViewModelTests {

    private let iso = ISO8601DateFormatter()

    private func makeBook(_ db: Database, id: String) throws {
        try db.execute(sql: """
            INSERT INTO audiobook (id, title, author, duration, added_at)
            VALUES (?, 'B', 'A', 3600, ?)
            """, arguments: [id, iso.string(from: Date())])
    }

    /// epub_block + a timeline_item pointing at it with the given audio_start_time.
    private func insertBlockWithTimeline(
        _ db: Database,
        audiobookID: String,
        blockID: String,
        chapterIndex: Int,
        audioStart: Double
    ) throws {
        // D4: epub_block requires NOT NULL spine_href, spine_index, block_index (+ is_hidden).
        try db.execute(sql: """
            INSERT INTO epub_block
              (id, audiobook_id, spine_href, spine_index, block_index,
               sequence_index, block_kind, text, chapter_index, is_hidden)
            VALUES (?, ?, 'spine.xhtml', 0, 0, 0, 'paragraph', 'x', ?, 0)
            """, arguments: [blockID, audiobookID, chapterIndex])
        // D5: timeline_item requires NOT NULL title.
        try db.execute(sql: """
            INSERT INTO timeline_item
              (id, audiobook_id, item_type, epub_block_id, audio_start_time,
               title, is_enabled, created_at)
            VALUES (?, ?, 'textSegment', ?, ?, 'Block', 1, ?)
            """, arguments: ["ti-\(blockID)", audiobookID, blockID, audioStart,
                             iso.string(from: Date())])
    }

    private func insertBookmark(
        _ db: Database,
        audiobookID: String,
        mediaTimestamp: Double,
        createdAt: Date
    ) throws {
        // D3: bookmark has media_timestamp (NOT NULL), title (NOT NULL); no 'position' column.
        try db.execute(sql: """
            INSERT INTO bookmark (id, audiobook_id, title, media_timestamp, created_at)
            VALUES (?, ?, 'Mark', ?, ?)
            """, arguments: [UUID().uuidString, audiobookID, mediaTimestamp,
                             iso.string(from: createdAt)])
    }

    @Test func recapDerivesChapterRangeFromCoveredPositions() throws {
        let db = try DatabaseService(inMemory: ())
        let bookID = "B"
        try db.writer.write { db in
            try makeBook(db, id: bookID)
            // Chapter 0 starts at audio 0, chapter 1 at 600, chapter 2 at 1200.
            try insertBlockWithTimeline(db, audiobookID: bookID, blockID: "c0", chapterIndex: 0, audioStart: 0)
            try insertBlockWithTimeline(db, audiobookID: bookID, blockID: "c1", chapterIndex: 1, audioStart: 600)
            try insertBlockWithTimeline(db, audiobookID: bookID, blockID: "c2", chapterIndex: 2, audioStart: 1200)
        }
        // Covered range 120…720 spans chapter 0 (0) and chapter 1 (600), not chapter 2.
        let window = FeedScopeWindow(
            startedAt: iso.date(from: "2026-06-22T10:00:00Z")!,
            endedAt: iso.date(from: "2026-06-22T10:30:00Z")!,
            coveredStartPosition: 120, coveredEndPosition: 720, listenedSeconds: 900)

        let vm = SessionRecapViewModel(db: db.writer)
        let recap = try vm.recap(audiobookID: bookID, window: window)

        #expect(recap.coveredChapterIndices == [0, 1])
        #expect(recap.listenedSeconds == 900)
        #expect(recap.startedAt == window.startedAt)
    }

    @Test func recapCountsBookmarksCreatedInWindowOnly() throws {
        let db = try DatabaseService(inMemory: ())
        let bookID = "B"
        let base = iso.date(from: "2026-06-22T10:00:00Z")!
        let window = FeedScopeWindow(
            startedAt: base, endedAt: base.addingTimeInterval(1800),
            coveredStartPosition: 0, coveredEndPosition: 10, listenedSeconds: 60)
        try db.writer.write { db in
            try makeBook(db, id: bookID)
            try insertBookmark(db, audiobookID: bookID, mediaTimestamp: 5,
                               createdAt: base.addingTimeInterval(60))   // inside
            try insertBookmark(db, audiobookID: bookID, mediaTimestamp: 7,
                               createdAt: base.addingTimeInterval(120))  // inside
            try insertBookmark(db, audiobookID: bookID, mediaTimestamp: 1,
                               createdAt: base.addingTimeInterval(-3600)) // before → excluded
        }
        let vm = SessionRecapViewModel(db: db.writer)
        let recap = try vm.recap(audiobookID: bookID, window: window)
        #expect(recap.bookmarkCount == 2)
    }

    @Test func recapWithNoCoverageHasEmptyChapterRange() throws {
        let db = try DatabaseService(inMemory: ())
        let bookID = "B"
        try db.writer.write { db in try makeBook(db, id: bookID) }
        let window = FeedScopeWindow(
            startedAt: Date(), endedAt: Date(),
            coveredStartPosition: 0, coveredEndPosition: 0, listenedSeconds: 0)
        let vm = SessionRecapViewModel(db: db.writer)
        let recap = try vm.recap(audiobookID: bookID, window: window)
        #expect(recap.coveredChapterIndices.isEmpty)
        #expect(recap.bookmarkCount == 0)
    }
}
```

> **NOTE on `bookmark` columns (D3):** the fixture uses the verified real schema: `id` (PK), `audiobook_id` (NOT NULL), `title` (NOT NULL), `media_timestamp` (NOT NULL), `created_at` (NOT NULL). There is no `position` column — an earlier plan draft invented one. The production SQL in `SessionRecapViewModel` queries `bookmark` by `created_at` window, which matches `created_at TEXT NOT NULL DEFAULT (datetime('now'))` in `Schema_V1.swift:51`.

Run it (expect: does-not-compile):

```
make build-tests
```

Expected: compile error `cannot find 'SessionRecapViewModel' in scope`.

- [ ] **Step 2: Implement `SessionRecapViewModel`**

Create `EchoCore/ViewModels/SessionRecapViewModel.swift`:

```swift
// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import GRDB

/// Metadata for the recap card shown atop a scoped feed. All fields are derived at
/// query time from existing tables — no stored session summary, no schema change.
/// GPS ("where") is deferred to Phase 5 (the `session_location` table has no writer).
public struct SessionRecap: Equatable, Sendable {
    public let startedAt: Date
    public let listenedSeconds: TimeInterval
    public let coveredChapterIndices: [Int]
    public let bookmarkCount: Int
    public let cardCount: Int

    public init(
        startedAt: Date,
        listenedSeconds: TimeInterval,
        coveredChapterIndices: [Int],
        bookmarkCount: Int,
        cardCount: Int
    ) {
        self.startedAt = startedAt
        self.listenedSeconds = listenedSeconds
        self.coveredChapterIndices = coveredChapterIndices
        self.bookmarkCount = bookmarkCount
        self.cardCount = cardCount
    }
}

/// Builds a `SessionRecap` from a resolved `FeedScopeWindow`. GRDB read-only struct.
public struct SessionRecapViewModel {
    public let db: DatabaseWriter

    public init(db: DatabaseWriter) {
        self.db = db
    }

    private static let iso = ISO8601DateFormatter()

    public func recap(audiobookID: String, window: FeedScopeWindow) throws -> SessionRecap {
        try db.read { db in
            // Covered chapter range: distinct chapter indices whose timeline items'
            // audio_start_time falls in the covered position range.
            var chapters: [Int] = []
            if window.coveredEndPosition > window.coveredStartPosition {
                let rows = try Row.fetchAll(db, sql: """
                    SELECT DISTINCT eb.chapter_index AS chapter_index
                    FROM timeline_item ti
                    JOIN epub_block eb ON eb.id = ti.epub_block_id
                    WHERE ti.audiobook_id = ?
                      AND ti.audio_start_time >= ?
                      AND ti.audio_start_time <= ?
                      AND eb.chapter_index IS NOT NULL
                    ORDER BY eb.chapter_index
                    """, arguments: [audiobookID,
                                     window.coveredStartPosition,
                                     window.coveredEndPosition])
                chapters = rows.compactMap { $0["chapter_index"] as Int? }
            }

            // Bookmarks created inside the wall-clock window.
            let startStr = Self.iso.string(from: window.startedAt)
            let endStr = Self.iso.string(from: window.endedAt)
            let bookmarkCount = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM bookmark
                WHERE audiobook_id = ?
                  AND created_at >= ?
                  AND created_at <= ?
                """, arguments: [audiobookID, startStr, endStr]) ?? 0

            // Cards created in the window: counted from timeline_item rows of type
            // 'ankiCard' created in the window. Phase 2 surfaces these as feed items;
            // here we only count. If the card table differs, adjust the source table.
            let cardCount = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM timeline_item
                WHERE audiobook_id = ?
                  AND item_type = 'ankiCard'
                  AND created_at IS NOT NULL
                  AND created_at >= ?
                  AND created_at <= ?
                """, arguments: [audiobookID, startStr, endStr]) ?? 0

            return SessionRecap(
                startedAt: window.startedAt,
                listenedSeconds: window.listenedSeconds,
                coveredChapterIndices: chapters,
                bookmarkCount: bookmarkCount,
                cardCount: cardCount
            )
        }
    }
}
```

> **NOTE on `cardCount`:** the SQL counts `timeline_item` rows with `item_type = 'ankiCard'`. Confirm `TimelineItemType.ankiCard`'s raw value is `"ankiCard"` in `Shared/Database/TimelineItem.swift:21` before relying on it; adjust the string literal to the real raw value if it differs. The cardCount test is intentionally not asserted in Step 1 (no card fixture) to avoid pinning a column that may need confirmation — add a card-count test once the raw value and source table are verified.

- [ ] **Step 3: Run the test**

```
make build-tests
make test-only FILTER=EchoTests/SessionRecapViewModelTests
```

Expected: `Test Suite 'SessionRecapViewModelTests' passed` — 3 tests, 0 failures.

- [ ] **Step 4: Commit**

```
git add EchoCore/ViewModels/SessionRecapViewModel.swift EchoTests/SessionRecapViewModelTests.swift
git commit -m "feat(feed): add SessionRecapViewModel (derived recap metadata for scoped feed)"
```

---

## Task 5: Wire filter + scope into `ReaderFeedViewModel`

Add the observed `filter`, resolve scope on change, run the pure content-type filter inside the Phase-1 `rebuildDisplaySections()`, build the recap, and add the session-start auto-expand (Trap H).

**Files:**
- Modify: `EchoCore/ViewModels/ReaderFeedViewModel.swift`
- Test: `EchoTests/ReaderFeedViewModelAccordionTests.swift` *(append)*

**Interfaces:**
- Consumes: `FeedFilter`, `FeedScopeResolver`, `ReaderFeedDisplayBuilder.applyFilter`, `SessionRecapViewModel`.
- Produces: `var filter: FeedFilter` (observed), `private(set) var scopeWindow: FeedScopeWindow?`, `private(set) var recap: SessionRecap?`, `func expandChapter(forSessionStart:)`.

- [ ] **Step 1: Write the failing test (append to the accordion suite)**

Append these tests to `EchoTests/ReaderFeedViewModelAccordionTests.swift`. The suite already defines `seed() -> DatabaseService` (audiobookID `"bk"`) which sets **chapter 1 = audio, chapter 0 = no-audio** (D6: this is the real convention — opposite of what an earlier draft assumed). The suite is a plain `@MainActor struct` with a synchronous `reload()` call; no `async`/`Task.yield()` is needed. Use `chapterKey(forSectionID: $0.id) ?? -1` (the real API — D1).

```swift
    @Test func settingAudioFilterDropsTextChapterFromDisplay() throws {
        let db = try seed() // ch1 = audio, ch0 = no-audio
        let bookID = "bk"
        let vm = ReaderFeedViewModel(audiobookID: bookID, db: db.writer)
        vm.reload()

        // Sanity: both chapters present under .everything.
        let allKeys = Set(vm.displaySections.map {
            ReaderFeedDisplayBuilder.chapterKey(forSectionID: $0.id) ?? -1
        })
        #expect(allKeys.contains(1))  // audio chapter
        #expect(allKeys.contains(0))  // text-only chapter

        vm.filter.contentType = .audio

        let audioKeys = Set(vm.displaySections.map {
            ReaderFeedDisplayBuilder.chapterKey(forSectionID: $0.id) ?? -1
        })
        #expect(audioKeys.contains(1))   // audio chapter retained
        #expect(!audioKeys.contains(0))  // text-only chapter dropped
    }

    @Test func settingTextFilterKeepsOnlyNoAudioChapter() throws {
        let db = try seed()
        let vm = ReaderFeedViewModel(audiobookID: "bk", db: db.writer)
        vm.reload()

        vm.filter.contentType = .text

        let keys = Set(vm.displaySections.map {
            ReaderFeedDisplayBuilder.chapterKey(forSectionID: $0.id) ?? -1
        })
        #expect(keys == [0]) // ch0 is the text-only chapter (D6: ch1=audio, ch0=no-audio)
    }

    @Test func resettingToEverythingRestoresAllChapters() throws {
        let db = try seed()
        let vm = ReaderFeedViewModel(audiobookID: "bk", db: db.writer)
        vm.reload()

        vm.filter.contentType = .audio
        vm.filter.contentType = .everything

        let keys = Set(vm.displaySections.map {
            ReaderFeedDisplayBuilder.chapterKey(forSectionID: $0.id) ?? -1
        })
        #expect(keys.contains(1))
        #expect(keys.contains(0))
    }

    @Test func wholeBookScopeHasNoRecap() throws {
        let db = try seed()
        let vm = ReaderFeedViewModel(audiobookID: "bk", db: db.writer)
        vm.reload()
        #expect(vm.filter.scope == .wholeBook)
        #expect(vm.recap == nil)
        #expect(vm.scopeWindow == nil)
    }
```

> **NOTE (D6/D7):** confirm the exact helper name and return type in `ReaderFeedViewModelAccordionTests.swift` before running — the real helper is `seed() -> DatabaseService` (not `seedTwoChapterBook`), the real audiobookID is `"bk"`, and the real audio convention is ch1=audio/ch0=no-audio. If `reload()` is async in the committed Phase-1 Task 4 implementation, add `try await` and `async throws` to the test signatures. Also confirm `expandChapter` entry-point names have not drifted (D7): Phase-1 Task 4 may commit `expandChapter(containingBlockID:)` with a different or additional signature; do not add a conflicting third overload when adding `expandChapter(forSessionStart:)` in Task 5 Step 3.

Run it (expect: does-not-compile — `filter`/`recap`/`scopeWindow` undefined):

```
make build-tests
```

Expected: compile error `value of type 'ReaderFeedViewModel' has no member 'filter'`.

- [ ] **Step 2: Add the stored properties**

In `EchoCore/ViewModels/ReaderFeedViewModel.swift`, near the other Phase-1 published properties (after `openChapterKey`), add:

```swift
    /// Phase-3 two-axis filter (content type × scope). Setting it re-derives the feed.
    var filter: FeedFilter = FeedFilter() {
        didSet {
            guard filter != oldValue else { return }
            if filter.scope != oldValue.scope {
                resolveScope()
            }
            rebuildDisplaySections()
        }
    }

    /// The resolved window for the current scope (nil under `.wholeBook`).
    private(set) var scopeWindow: FeedScopeWindow?

    /// The recap card metadata for the current scoped window (nil under `.wholeBook`).
    private(set) var recap: SessionRecap?
```

> **NOTE:** `ReaderFeedViewModel` is `@Observable`. With a stored property that has a `didSet`, observation still fires on assignment because the macro instruments the setter. If the project pins observation to specific accessors and `didSet` interferes, move the re-derivation out of `didSet` into an explicit `applyFilter(_:)` method and call it from the view's `onChange`; the tests above assign `vm.filter.x` then `await Task.yield()`, which works with either wiring. Prefer `didSet` unless it breaks `@Observable`.

- [ ] **Step 3: Add scope resolution**

Add this method to `ReaderFeedViewModel`:

```swift
    /// Resolves the current `filter.scope` to a `scopeWindow` + `recap`, off the
    /// stored `audiobookID` (the GRDB UUID used by `playback_event`). Synchronous
    /// GRDB reads on a few rows — within smooth-scroll budget (Phase-3 Trap B).
    private func resolveScope() {
        switch filter.scope {
        case .wholeBook:
            scopeWindow = nil
            recap = nil
        case .lastSession:
            let resolver = FeedScopeResolver(db: db)
            let window = (try? resolver.lastSessionWindow(audiobookID: audiobookID)) ?? nil
            scopeWindow = window
            if let window {
                recap = try? SessionRecapViewModel(db: db).recap(audiobookID: audiobookID, window: window)
                expandChapter(forSessionStart: window.coveredStartPosition)
            } else {
                recap = nil
            }
        case let .session(id, _, _):
            let resolver = FeedScopeResolver(db: db)
            let window = (try? resolver.sessionWindow(id: id, audiobookID: audiobookID)) ?? nil
            scopeWindow = window
            if let window {
                recap = try? SessionRecapViewModel(db: db).recap(audiobookID: audiobookID, window: window)
                expandChapter(forSessionStart: window.coveredStartPosition)
            } else {
                recap = nil
            }
        }
    }

    /// Auto-expands the chapter that contains `position` (book seconds), mapping the
    /// position to a chapter index via timeline_item → epub_block, then opening it
    /// (Phase-3 Trap H — a new auto-expand trigger beyond Phase-1's isPlaying one).
    func expandChapter(forSessionStart position: TimeInterval) {
        let key: Int? = (try? db.read { db in
            try Int.fetchOne(db, sql: """
                SELECT eb.chapter_index
                FROM timeline_item ti
                JOIN epub_block eb ON eb.id = ti.epub_block_id
                WHERE ti.audiobook_id = ?
                  AND ti.audio_start_time <= ?
                  AND eb.chapter_index IS NOT NULL
                ORDER BY ti.audio_start_time DESC
                LIMIT 1
                """, arguments: [audiobookID, position])
        }) ?? nil
        if let key {
            openChapterKey = key
        }
    }
```

> **NOTE:** `let resolver = FeedScopeResolver(db: db)` requires `db` to be the VM's `DatabaseWriter` (it is — `ReaderFeedViewModel.swift:18` `private let db: DatabaseWriter`). `expandChapter(forSessionStart:)` sets `openChapterKey`, which must trigger `rebuildDisplaySections()`. If `openChapterKey` already has a Phase-1 `didSet` that rebuilds, do not double-rebuild; otherwise call `rebuildDisplaySections()` after setting it. Verify against the Phase-1 implementation.

- [ ] **Step 4: Apply the content-type filter inside `rebuildDisplaySections()`**

Find the Phase-1 `private func rebuildDisplaySections()`. It currently does something like:

```swift
    // Phase 1 (existing):
    // displaySections = ReaderFeedDisplayBuilder.displaySections(
    //     groups: chapterGroups, openChapterKey: openChapterKey)
```

Change the assignment so the content-type filter runs **after** grouping/accordion (Trap G):

```swift
    private func rebuildDisplaySections() {
        let grouped = ReaderFeedDisplayBuilder.displaySections(
            groups: chapterGroups,
            openChapterKey: openChapterKey)
        displaySections = ReaderFeedDisplayBuilder.applyFilter(
            filter.contentType,
            to: grouped,
            chapterHasAudio: chapterHasAudio)
    }
```

> **NOTE:** copy the exact Phase-1 call (`groups:` / `openChapterKey:` argument labels and the source array name `chapterGroups`) from the current `rebuildDisplaySections()` — names may differ slightly. The only change is wrapping the result in `applyFilter(...)`. Do not alter the grouping/accordion logic.

- [ ] **Step 5: Resolve scope on `reload()`**

At the end of `reload()` (after `chapterHasAudio` is populated and `rebuildDisplaySections()` would run), ensure scope is re-resolved so a non-default scope survives a reload. Add, right before/where the Phase-1 `reload()` finishes its display build:

```swift
        // Phase 3: re-resolve scope after a reload (covered range depends on freshly
        // loaded blocks; whole-book is a no-op).
        if filter.scope != .wholeBook {
            resolveScope()
        }
```

> **NOTE:** if `reload()` calls `rebuildDisplaySections()` itself, `resolveScope()` already triggers it via `expandChapter`/`openChapterKey`; avoid a redundant rebuild. Place this call after `chapterHasAudio` is set, since `applyFilter` reads it.

- [ ] **Step 6: Run the tests**

```
make build-tests
make test-only FILTER=EchoTests/ReaderFeedViewModelAccordionTests
```

Expected: `Test Suite 'ReaderFeedViewModelAccordionTests' passed` — the 4 new tests plus all pre-existing Phase-1 accordion tests, 0 failures.

- [ ] **Step 7: Commit**

```
git add EchoCore/ViewModels/ReaderFeedViewModel.swift EchoTests/ReaderFeedViewModelAccordionTests.swift
git commit -m "feat(feed): wire two-axis filter + last-session scope + recap into ReaderFeedViewModel"
```

---

## Task 6: Filter chip row + scope selector + recap card in `ReaderTab`

Add the SwiftUI chip row (content type) and scope selector above the feed, render the recap card when scoped, and bind `vm.filter`. Bookmarks/Cards chips ship disabled (fork 3).

**Files:**
- Modify: `EchoCore/Views/ReaderTab.swift`
- *(No test — SwiftUI view wiring is build-verified + on-device smoke; pure logic is already covered by Tasks 1–5.)*

**Interfaces:**
- Consumes: `vm.filter` (`@Bindable`), `vm.recap`, `FeedContentType.allCases`.
- Produces: chip row UI + recap card UI; routes selection to `vm.filter.contentType` / `vm.filter.scope`.

- [ ] **Step 1: Add the chip row + scope selector view**

In `EchoCore/Views/ReaderTab.swift`, add a private subview. (Confirm the file's existing access to `vm` as `@Bindable var vm: ReaderFeedViewModel` or `@State`/`@Environment`; the snippet assumes a `@Bindable` binding is available — adapt the binding source to the file's actual pattern.)

```swift
    /// Phase-3 content-type chips + scope selector. Sits directly above the feed.
    @ViewBuilder
    private func filterBar(_ vm: ReaderFeedViewModel) -> some View {
        VStack(spacing: 8) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(FeedContentType.allCases, id: \.self) { type in
                        let disabled = (type == .bookmarks || type == .cards) // fork 3: Phase 2 dep
                        Button {
                            vm.filter.contentType = type
                        } label: {
                            Text(Self.chipLabel(type))
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    Capsule().fill(vm.filter.contentType == type
                                        ? Color.accentColor.opacity(0.2)
                                        : Color.secondary.opacity(0.12)))
                                .overlay(
                                    Capsule().stroke(vm.filter.contentType == type
                                        ? Color.accentColor : .clear, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .disabled(disabled)
                        .opacity(disabled ? 0.4 : 1)
                        .accessibilityLabel(Self.chipLabel(type))
                        .accessibilityAddTraits(vm.filter.contentType == type ? [.isSelected] : [])
                    }
                }
                .padding(.horizontal)
            }

            Picker("Scope", selection: Binding(
                get: { vm.filter.scope == .wholeBook ? 0 : 1 },
                set: { vm.filter.scope = ($0 == 0) ? .wholeBook : .lastSession }
            )) {
                Text("Whole book").tag(0)
                Text("Last session").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
        }
        .padding(.vertical, 6)
    }

    private static func chipLabel(_ type: FeedContentType) -> String {
        switch type {
        case .everything: return "Everything"
        case .audio: return "Audio"
        case .text: return "Text"
        case .pics: return "Pics"
        case .picsAndAudio: return "Pics + Audio"
        case .bookmarks: return "Bookmarks"
        case .cards: return "Cards"
        }
    }
```

> **NOTE on binding source:** `vm.filter.contentType = type` requires `vm` to be mutable-observed. If `ReaderTab` holds `vm` via `@Environment` or a non-`@Bindable` `@State`, the assignment still works on a reference-type `@Observable` (it's reference mutation, not value rebinding). The `Picker` binding is a manual `Binding` to translate the two-case scope; this avoids needing `FeedScope: Hashable` for `.tag`. The disabled Bookmarks/Cards chips are present so the bar's final shape is locked; Phase 2 deletes the `disabled` line.

- [ ] **Step 2: Add the recap card view**

Add another private subview to `ReaderTab.swift`:

```swift
    /// Phase-3 recap card shown atop a scoped feed (only when `.lastSession` resolves).
    @ViewBuilder
    private func recapCard(_ recap: SessionRecap) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Last session")
                .font(.headline)
            HStack(spacing: 16) {
                label("clock", Self.minutesText(recap.listenedSeconds))
                if !recap.coveredChapterIndices.isEmpty {
                    label("book", Self.chaptersText(recap.coveredChapterIndices))
                }
                if recap.bookmarkCount > 0 {
                    label("bookmark", "\(recap.bookmarkCount)")
                }
                if recap.cardCount > 0 {
                    label("rectangle.on.rectangle", "\(recap.cardCount)")
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            Text(recap.startedAt, style: .date)
                .font(.caption)
                .foregroundStyle(.tertiary)
            // GPS ("where") deferred to Phase 5 — session_location has no writer yet.
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.1)))
        .padding(.horizontal)
    }

    @ViewBuilder
    private func label(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).labelStyle(.titleAndIcon)
    }

    private static func minutesText(_ seconds: TimeInterval) -> String {
        let mins = Int((seconds / 60).rounded())
        return "\(mins) min"
    }

    private static func chaptersText(_ indices: [Int]) -> String {
        guard let first = indices.first, let last = indices.last else { return "" }
        // chapter index is 0-based; show 1-based to the reader.
        return first == last ? "Ch \(first + 1)" : "Ch \(first + 1)–\(last + 1)"
    }
```

- [ ] **Step 3: Insert the bar + recap into the feed layout**

Find where `ReaderTab` builds the feed body (the `feedCollectionView` host, around `ReaderTab.swift:87`). Wrap it so the chip bar sits above the feed and the recap card sits above the feed when present:

```swift
        VStack(spacing: 0) {
            filterBar(vm)
            if let recap = vm.recap {
                recapCard(recap)
                    .padding(.bottom, 8)
            }
            feedCollectionView // existing host, now driven by vm.displaySections (Phase 1)
        }
```

> **NOTE (M1):** `ReaderTab` holds `@State var viewModel: ReaderFeedViewModel?` (optional), not `@Bindable var vm`. When inserting the `filterBar(vm)` / `recapCard(recap)` calls, unwrap the optional first (e.g. `if let vm = viewModel { ... }`). Keep `EPUBTOCSheet` and the chapter-theme picker reading `vm.sections` (the unfiltered full list) — they are unaffected by Phase 3 (the filter only narrows `vm.displaySections`, which is what `feedCollectionView` already consumes after Phase 1). Do not point the sheet at `displaySections`. Also: `feedCollectionView` currently passes `sections: vm.sections` — after Phase-1 Task 4 rewires it to `displaySections`, confirm that change is committed before inserting the Phase-3 filter bar.

- [ ] **Step 4: Build-verify**

```
make build-tests
```

Expected: build succeeds (this also compiles the test target). No new compile errors in `ReaderTab.swift`.

- [ ] **Step 5: Commit**

```
git add EchoCore/Views/ReaderTab.swift
git commit -m "feat(feed): add filter chip row, scope selector, and last-session recap card to ReaderTab"
```

---

## Task 7: Full-suite smoke, on-device check, doc-sync, PR

**Files:**
- Modify: `ARCHITECTURE.md`, `CHANGELOG.md` (doc-sync)
- *(No new code.)*

- [ ] **Step 1: Run the whole EchoTests suite (regression gate)**

Confirm the overnight build slot is idle first, then:

```
make build-tests
make test-only FILTER=EchoTests
```

Expected: all suites pass, including the 4 new suites (`FeedFilterModelTests`, `FeedScopeResolverTests`, `ReaderFeedDisplayBuilderFilterTests`, `SessionRecapViewModelTests`) and the extended `ReaderFeedViewModelAccordionTests`. 0 new failures vs. the Phase-1 baseline (note any pre-existing failures unrelated to this work and do not let them block).

- [ ] **Step 2: On-device / simulator smoke (owner-runnable checklist)**

Document these manual checks (the engineer runs them on the iPhone 17 sim or a device):
- Open a book with mixed audio/text chapters. Tap **Audio** chip → only audio chapters show; tap **Text** → only text-only chapters; tap **Everything** → all return.
- Tap **Pics** on a book with images → only chapters containing images, showing image blocks; headers present, paragraph-only chapters hidden.
- **Bookmarks** and **Cards** chips render but are greyed/non-selectable (Phase 2 dependency).
- Switch scope to **Last session** on a book you've listened to → recap card appears (minutes, chapter range, date); the session's first chapter auto-expands. Switch back to **Whole book** → recap disappears, accordion returns to default.
- `EPUBTOCSheet` still opens and lists all chapters regardless of the active chip (it reads `vm.sections`).

- [ ] **Step 3: Doc-sync**

This phase adds a feature (filters + session scope) and a derivation pattern (recap from `real_time_event` + `playback_event`) but **no schema change**. Update:
- `ARCHITECTURE.md`: under the Unified Feed / Reader section, note the two-axis filter (`FeedFilter` pure value; content-type predicate in `ReaderFeedDisplayBuilder.applyFilter`; scope resolved by `FeedScopeResolver` from `real_time_event` window + `playback_event` derived range), the recap card (`SessionRecapViewModel`, GPS deferred), and the explicit "no `playback_session` table; covered range is derived, not stored" note.
- `CHANGELOG.md`: add an entry under the unreleased/nightly section.

Run the `doc-sync` skill to confirm nothing else is stale.

- [ ] **Step 4: Commit docs**

```
git add ARCHITECTURE.md CHANGELOG.md
git commit -m "docs(feed): document Phase 3 two-axis filter + session-scope recap"
```

- [ ] **Step 5: Open the PR against nightly**

```
git push -u origin feature/unified-feed-phase1
gh pr create --base nightly --title "feat(feed): unified feed Phase 3 — filters + session scope" --body "$(cat <<'EOF'
## Summary
Unified Feed Phase 3: a two-dimensional filter over the reader feed.

- **Content-type axis** (`FeedContentType`): Everything / Audio / Text / Pics / Pics+Audio / Bookmarks(disabled) / Cards(disabled). Pure predicate applied after Phase-1 grouping/accordion via `ReaderFeedDisplayBuilder.applyFilter`.
- **Scope axis** (`FeedScope`): Whole book / Last session. `FeedScopeResolver` derives the session window from `real_time_event` (`playback_session`) and the covered book-position range + minutes from `playback_event` — no `playback_session` table, no denormalized cache, no schema change.
- **Recap card** atop a scoped feed (`SessionRecapViewModel`): listened minutes, covered chapter range, bookmark/card counts. GPS ("where") deferred to Phase 5 (`session_location` has no writer).

## Forks / defaults (owner review)
1. GPS deferred to Phase 5.
2. Bookmarks/Cards = individual chips (not a "Marks" group).
3. Bookmarks/Cards chips ship disabled until Phase 2 adds the `ReaderCardItem` cases.
4. "Text" = chapters without audio.
5. Scope this phase = Whole book + Last session only (session picker deferred).

## Tests
New: `FeedFilterModelTests`, `FeedScopeResolverTests`, `ReaderFeedDisplayBuilderFilterTests`, `SessionRecapViewModelTests`. Extended: `ReaderFeedViewModelAccordionTests`. Full `EchoTests` suite green.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

---

## Self-Review

**1. Spec coverage (Phase 3 scope per spec §6, §9, §12):**
- Two-dimensional model from the start (content-type axis × scope axis): `FeedFilter` (Task 1), applied in the VM (Task 5). ✓
- Content chips UI (Everything/Audio/Text/Pics/Pics+Audio/Bookmarks/Cards): `filterBar` (Task 6) over `FeedContentType.allCases`. ✓
- Content predicate over read-model flags/item types: `applyFilter` chapter-level (Audio/Text via `chapterHasAudio`) + block-level (Pics/Pics+Audio via `blockKind == "image"`) (Task 3). ✓
- Images render inline in-context when expanded: Pics keeps image blocks inside their (expandable) chapter groups; no separate gallery. ✓
- "Last session" scope + recap card atop the scoped feed: `FeedScopeResolver` + `SessionRecapViewModel` + `recapCard` (Tasks 2/4/6). ✓
- Covered position range verified derived (not stored) and reconstruction is cheap → no cache (spec §9 instruction honored). ✓
- Open Q §13.5 (Bookmarks/Cards chip vs "Marks" group): default = individual chips, flagged (fork 2). ✓
- GPS / `session_location` decision: deferred to Phase 5, flagged (fork 1) since the table has no writer. ✓

**2. Placeholder scan:** every code step shows complete Swift; every test step shows complete test code + exact command + expected output. The only deferred-to-execution items are clearly-marked verification NOTEs that ask the implementer to confirm an exact column name / Phase-1 helper name against the live code before relying on a literal — these are correctness guards, not code placeholders. No "TBD"/"add error handling"/"similar to Task N". ✓

**3. Type consistency:**
- `FeedContentType` cases identical across Task 1 (def), Task 3 (`applyFilter`), Task 6 (`chipLabel`, `allCases` chips), and the `allCasesAreEnumerable` test. ✓
- `FeedFilter(contentType:scope:)` init labels identical Task 1 ↔ Task 5 ↔ Task 6. ✓
- `FeedScopeWindow(startedAt:endedAt:coveredStartPosition:coveredEndPosition:listenedSeconds:)` identical Task 2 (def + tests) ↔ Task 4 (consumed) ↔ Task 5 (assigned). ✓
- `FeedScopeResolver(db:)`, `lastSessionWindow(audiobookID:)`, `sessionWindow(id:audiobookID:)` identical Task 2 ↔ Task 5. ✓
- `ReaderFeedDisplayBuilder.applyFilter(_:to:chapterHasAudio:)` identical Task 3 (def) ↔ Task 5 (call). ✓
- `SessionRecap(startedAt:listenedSeconds:coveredChapterIndices:bookmarkCount:cardCount:)` + `SessionRecapViewModel(db:).recap(audiobookID:window:)` identical Task 4 ↔ Task 5. ✓
- `chapterKey(forSectionID:) -> Int?` is the real API (`ReaderFeedDisplayBuilder.swift:25`); all calls use `chapterKey(forSectionID: section.id) ?? -1`. The earlier draft's invented `chapterKey(forSection:) -> Int` overload has been removed (D1). ✓
- Header item id `"ch-\(chapterIndex)"` / block id `"b-\(block.id)"` assumed by the Task 3 tests match `ReaderCardItem.id` (Phase-1 fact). ✓

**Known risks carried into execution (each has a guard):**
- Folder-URL-vs-UUID mismatch (Trap A): resolver never JOINs the two tables on `audiobook_id`; it orders `real_time_event` by recency then intersects `playback_event` (by GRDB UUID) on `started_at`. `FeedScopeResolverTests.lastSessionDerivesWindowAndCoveredRange` exercises an out-of-window segment exclusion.
- `EPubBlockRecord` memberwise-init (Task 3 fixtures): **resolved (D2)** — full verified init with `spineHref`/`spineIndex`/`blockIndex`/`isHidden` etc.; `alignmentStatus`/`audioStartTime` do not exist and were removed.
- `bookmark` columns (Task 4): **resolved (D3)** — `media_timestamp` (NOT NULL) used instead of the non-existent `position`; `title` NOT NULL added.
- `epub_block` INSERT (Task 4): **resolved (D4)** — `spine_href`/`spine_index`/`block_index`/`is_hidden` added.
- `timeline_item` INSERT (Task 4): **resolved (D5)** — NOT NULL `title` added.
- `TimelineItemType.ankiCard` raw value: still needs confirmation against live source; cardCount left untested.
- `@Observable` + `didSet` re-derivation (Task 5): NOTE offers an `applyFilter(_:)` fallback if `didSet` interferes; tests use `await Task.yield()` so they pass under either wiring.
- Double-rebuild on `openChapterKey`/`reload` (Task 5 Steps 3/5): NOTEs flag the redundancy to check against the Phase-1 `rebuildDisplaySections()` trigger.
- Bookmarks/Cards chips before Phase 2 (Trap D): shipped disabled; `applyFilter` predicate is a pass-through; `bookmarksChipIsPassThroughUntilPhase2` pins it.

---

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-22-unified-feed-phase3.md`. Two execution options:

1. **Subagent-Driven (recommended)** — dispatch a fresh subagent per task, review between tasks, fast iteration. Tell each implementer: builds run in the **foreground** with `timeout: 600000`; confirm the overnight build slot is idle first; before any task touching the live schema/types (Tasks 3/4/5), resolve the NOTE'd column/label/helper-name confirmations against the actual files. **BLOCKER (B1): Tasks 3, 5, and 6 MUST NOT start until Phase-1 Task 4 is committed** — `displaySections`/`chapterHasAudio`/`openChapterKey`/`toggleChapter`/`rebuildDisplaySections()` do not yet exist on this branch (accordion test file is untracked). Tasks 1 and 2 are independent and can proceed immediately. The Bookmarks/Cards chips depend on Phase 2 only for going live (they ship disabled regardless).
2. **Inline Execution** — execute tasks in this session using executing-plans, batch execution with checkpoints.

Which approach?
