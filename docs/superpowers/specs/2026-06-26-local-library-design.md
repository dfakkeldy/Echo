# On-Device Library — Browsable Shelf + Folder Roots

- **Status:** Approved design (pending implementation plan)
- **Date:** 2026-06-26
- **Author:** Dan Fakkeldy (with Claude)
- **Branch base:** `nightly` (worktree `claude/practical-robinson-29c8a5`, reset onto `origin/nightly` @ `234e716` / PR #199)
- **Origin:** Owner request — a "media library" like **foobar2000 mobile (iOS)**: add folders, index them, and browse the collection by author / topic / folder / status, with an explicit rescan instead of live folder-watching (which iOS does not permit). Scoped during this session to two components: **(A)** browse the books you've already added, and **(D)** add folders as "library roots" you can rescan, plus auto-registering any folder you open through the picker.

## 1. Summary

Echo today is **single-book-at-a-time**: [`PlayerModel`](../../../EchoCore/ViewModels/PlayerModel.swift) holds exactly one `folderURL`, and opening another book *replaces* it. There is no surface anywhere that enumerates your collection — yet the per-book metadata for one already lives in the `audiobook` table. This spec adds a **Library**: a launcher layer *above* the existing player that lists every book you've added, lets you browse it by several axes, and lets you register folders ("roots") that a manual **Rescan** sweeps for new books. Selecting a book re-acquires file access and calls the existing `loadFolder(url:)` — **playback and the single-book model are untouched.**

The expensive work (chapter parsing, EPUB block extraction, alignment) stays lazy: a rescan only does a **cheap metadata read** to make the shelf real, and the existing import path runs the first time you actually open a book.

## 2. Background & current state (verified this session)

A four-way parallel read of the codebase established the ground truth this design builds on:

- **No library UI exists.** The app lands on the current book; books are loaded one at a time via [`FolderPicker`](../../../EchoCore/Utilities/FolderPicker.swift) → `PlayerModel.loadFolder` or imported from Audiobookshelf. There is no cross-book browse anywhere.
- **The data is already there.** The `audiobook` row ([`AudiobookDAO`](../../../Shared/Database/DAOs/AudiobookDAO.swift)) carries `id` (normalized folder-URL string), `title`, `author` (free string, nullable), `duration`, `file_count`, `added_at`, `source_type` (`audiobookshelf`/local), `server_id`, `remote_item_id`, and `topics_json` (genres + tags + series, deduped). **It does *not* store cover art, narrator, an import-completeness flag, or availability.**
- **Genre and tags are not separable today.** ABS import merges genres + tags + series into the single `topics_json` set ([`ABSImportService`](../../../EchoCore/Services/Audiobookshelf/ABSImportService.swift)). So "Topic" is one combined facet unless a future migration splits them.
- **Security-scoped access is per-pick and only *one* bookmark is persisted.** [`Persistence.saveBookmark`](../../../EchoCore/Services/Persistence.swift) stores a single security-scoped bookmark for restoring the last book; [`SecurityScopeManager`](../../../EchoCore/Services/SecurityScopeManager.swift) tracks transient scopes. A multi-book library breaks this assumption — this is the central engineering lift (§7).
- **iOS cannot watch folders.** No `FSEvents`/`NSFilePresenter`/`DirectoryMonitor` anywhere; all imports are event-driven on explicit user action. A `.folder` pick grants **recursive** access to everything beneath it (exploited in §7).
- **Recursive scan heuristics already exist on macOS.** [`FolderAudioScanner`](../../../Echo%20macOS/Services/FolderAudioScanner.swift) does a one-time recursive enumerate (`.skipsHiddenFiles`, `.skipsPackageDescendants`) for the batch queue — the shared scanner (§8) generalizes this.
- **Metadata reads are available and cheap-ish.** [`ChapterService`](../../../EchoCore/Services/ChapterService.swift) uses `AVAsset.loadChapterMetadataGroups`; common metadata (title/author/artwork) is an `AVAsset` metadata load; EPUB title/author/cover come from the OPF.
- **Schema is at V26** (latest registered migration is `v26_timeline_segment_key`; V25 added study plans). Next free migration is **V27**.

## 3. Goals / non-goals

**Goals**

- A **Library** tab that browses every added book by: **All Books (A–Z)**, **Recently Added** (baseline) + **Author**, **Topic**, **Folder**, **Study status**, **Processing status** (aligned / transcribed / narrated).
- **Component D:** register folders as "library roots"; a manual **Rescan** discovers new books cheaply; any folder opened through the normal picker is auto-registered as a root.
- ABS-downloaded books appear in the **same** shelf — one unified collection, not a separate list.
- Smart landing: open to the current book if one is in progress, else to the Library.
- Non-destructive availability: unreachable books are hidden, never auto-deleted.

**Non-goals (this phase)**

- Live folder-watching (impossible on iOS; deferred to a macOS-only later phase).
- Full auto-import of every discovered book up front (rejected for memory/jetsam reasons — see §8).
- Auto-adding *document-only* books (standalone EPUB/MD/TXT with no audio) during a scan — excluded to avoid hoovering every EPUB in a Downloads folder (§13).
- The macOS UI surface — the core is built shared-ready, but Mac wiring is a fast-follow (§13).
- Multi-book playback, playlists, or cross-book notes — the player stays single-book.

## 4. Approved decisions (brainstorm outcomes)

| # | Decision | Choice |
|---|---|---|
| 1 | Navigation / landing | **Smart landing**: current book if in progress, else shelf; Library always a tab |
| 2 | Browse axes | All Books + Recently Added baseline **+ Author, Topic, Folder, Study status, Processing status** |
| 3 | Browse model | **Facet-chip cover grid** as default landing; **drill-down lists** reachable via "Browse by…" |
| 4 | Rescan cost | **Cheap metadata read**, defer heavy import to first open |
| 5 | Missing files | **Hidden by default + "Show unavailable" toggle**; never auto-delete; relocate/remove on explicit action |

## 5. Architecture — a launcher layer

Three new units, all in `Shared/` / `EchoCore` so the macOS target can adopt them later. Each has one purpose and a concrete, constructor-injected dependency set (following the `DatabaseService(inMemory:)` pattern — **no speculative protocols**):

- **`LibraryService`** — owns library reads and writes. Injected with `DatabaseService`, a `BookmarkStore` (§7), and a `LibraryScanner` (§8). Responsibilities: list books, group/sort by an axis, run rescans, compute & cache availability, resolve a book's file URL for opening.
- **`LibraryViewModel`** (`@Observable`) — view state for the Library tab: selected axis, current grouping/sections, search, "show unavailable" toggle, rescan progress.
- **`LibraryView`** (SwiftUI) — the facet-chip cover grid + "Browse by…" drill-down (§9).

**Opening a book** is the only coupling to the player: `LibraryService.urlForOpening(book)` re-acquires the security scope (§7), then the view calls the existing `PlayerModel.loadFolder(url:)`. **Smart landing** lives in [`RootTabView`](../../../EchoCore/Views/RootTabView.swift): on launch, if a book has in-progress playback, select Now Playing; otherwise select Library. "In progress" is derived from existing playback position state — no new storage.

```
LibraryView ──uses──▶ LibraryViewModel ──uses──▶ LibraryService
                                                   ├─ DatabaseService (audiobook / library_root rows)
                                                   ├─ BookmarkStore   (per-root + per-book scopes)
                                                   └─ LibraryScanner  (cheap discovery + metadata read)
   tap book ─────────────────────────────────────▶ PlayerModel.loadFolder(url:)   (unchanged)
```

## 6. Data model — V27 migration

A single additive migration `Schema_V27`. **Columns added to `audiobook`:**

| Column | Type | Purpose |
|---|---|---|
| `cover_art_path` | TEXT? | cached cover image (relative to a `LibraryCovers` caches dir); nil ⇒ render a generated placeholder |
| `narrator` | TEXT? | persist the ABS narrator (read but currently dropped); also read from M4B/EPUB when present |
| `index_state` | INTEGER NOT NULL DEFAULT 0 | `0` = shallow/indexed, `1` = fully imported — gates deferred import on first open |
| `is_available` | INTEGER NOT NULL DEFAULT 1 | cached availability; `false` ⇒ hidden unless "Show unavailable" |
| `last_seen_at` | TEXT? | ISO8601; refreshed when a scan/open confirms the file is reachable |
| `author_sort` | TEXT? | best-effort normalized grouping key (§12); display still uses raw `author` |
| `source_root_id` | TEXT? | FK → `library_root.id`; nil for standalone one-off picks |

**New table `library_root`:**

| Column | Type | Purpose |
|---|---|---|
| `id` | TEXT PK | stable id (UUID string) |
| `display_name` | TEXT | last path component, user-renamable later |
| `bookmark` | BLOB | security-scoped bookmark for the root folder |
| `added_at` | TEXT | ISO8601 |
| `last_scanned_at` | TEXT? | ISO8601 of the last successful rescan |

Existing columns already serve several axes for free: `topics_json` → **Topic**, `added_at` → **Recently Added**, `author` → **Author**. **Study status** and **Processing status** are *derived at query time*, not stored (§12).

**Migration-safety notes (for `schema-migration-reviewer`):** strictly additive (new nullable columns + new table; no edits to shipped migrations, no data rewrite); needs a `SchemaV27Tests`; does **not** force an EPUB re-import or alignment re-run. ⚠️ **Version number = V27:** V26 is already taken on `nightly` by `v26_timeline_segment_key` (merged), and the PDF Alignment initiative separately contends for a number — so the Library claims **V27** (`v27_library` / `Schema_V27`). Re-confirm `v27_*` is free against `Shared/Database/DatabaseService.runMigrations` before writing the migration.

## 7. Security-scope / access model — the central lift

`★` The key realization: an iOS `.folder` document-picker grant is **recursive** — one bookmark for a root unlocks every book beneath it. So we store a bookmark **per root**, not per book.

- Generalize today's single-bookmark store into a concrete **`BookmarkStore`** keyed by id (a `library_root.id` or, for standalone books, the `audiobook.id`). Backed by Keychain on device (as `Persistence` is today), with a **file-backed instance for tests** (a genuinely-wired test double — a legitimate concrete seam, not protocol theater; sidesteps the known sim-keychain flakiness).
- **Opening a book:**
  - `source_root_id != nil` → resolve the **root's** bookmark, `startAccessingSecurityScopedResource()` on the root, then reach through to the child URL.
  - `source_root_id == nil` (standalone pick) → resolve the book's **own** bookmark (existing behavior, now multi-record).
- **Availability** (`is_available`) is a cached boolean, recomputed (a) during a root rescan for that root's books, (b) lazily on an open attempt, and (c) by a bounded "verify visible books" pass when the Library tab appears. A bookmark that won't resolve ⇒ `is_available = false` ⇒ hidden. **iCloud-offloaded files count as available** (the bookmark resolves; the file downloads on open) — only an unresolvable bookmark marks a book unavailable.

`SecurityScopeManager`'s existing transient-scope lifecycle is reused for the *currently open* book; the new `BookmarkStore` only handles *persistence* of the many bookmarks.

## 8. Scan & index pipeline — cheap read, defer heavy work

A shared **`LibraryScanner`** generalizing the macOS `FolderAudioScanner` heuristics:

1. **Discover.** Recursively enumerate a root (`.skipsHiddenFiles`, `.skipsPackageDescendants`, bounded depth). A folder *directly containing* audio (`.m4b`/`.m4a`/`.mp3`) is one book; a lone `.m4b` is one book. Identity = the normalized folder-URL string (same key `loadFolder` already uses, so folder-open and single-file-open collapse to one identity).
2. **Classify against the DB** (match by id):
   - **New** → do a *light* metadata read only: title, author, narrator, topics, duration via `AVAsset` common metadata; extract a cover (priority: embedded M4B artwork → EPUB OPF cover → already-downloaded ABS cover → generated placeholder). Insert a **shallow** `audiobook` row: `index_state = 0`, `source_root_id = root`, `is_available = 1`, `last_seen_at = now`, `author_sort` computed.
   - **Known & present** → refresh `last_seen_at`, set `is_available = 1`.
   - **Known but absent this scan** (under a scanned root) → leave the row, set `is_available = 0`. **Never deleted.**
3. **Defer the heavy work.** Track enumeration, M4B chapter parsing, EPUB block extraction, and alignment finalize run on **first open**, via the existing [`PlayerLoadingCoordinator`](../../../EchoCore/Services/PlayerLoadingCoordinator.swift) import path, which then flips `index_state = 1`.

Rescan is **manual**: a per-root "Rescan" and a global "Rescan all", run in a bounded-concurrency `Task` (cap parallel `AVAsset` metadata loads to keep memory pressure down — the full-import path already strains past a handful of books per process on iOS) with progress surfaced in the UI.

## 9. Browse UI & navigation

- **Default landing (Option A):** a cover grid under a horizontal **facet-chip** row — *Recently · Authors · Topics · Folders · Status*. Selecting a chip re-groups the same grid in place into labeled sections. Each cover shows a **processing-status dot** (green = aligned, blue = narrated, amber = transcribed-only, grey = not processed), title, and author.
- **"Browse by…" (Option B drill-down):** opens a value list with counts for Authors / Topics / Folders / Study status / Processing status → tap a value → filtered grid. Calmer at large scale; complements the grid rather than replacing it.
- **Folder axis** renders the `library_root` set and walks subfolders (the foobar2000-style tree).
- **Sort** within a view: Title, Author, Recently Added, Duration.
- **Search**: title/author/narrator across the library (distinct from the existing per-book block search).
- **Opening** a book routes through smart-landing into the existing Now Playing / Read player.

## 10. Missing-file handling

Unavailable books (`is_available = 0`) are **hidden** by default. A toolbar **"Show unavailable"** toggle (and a **Manage roots** screen) reveals them, where the user can **Relocate** (re-pick the folder to refresh the bookmark) or **Remove**. Removal is the *only* path that deletes an `audiobook` row and its study data, and only on explicit action. Because iCloud-offload looks like deletion but isn't, we never act on absence automatically.

## 11. Component D — library roots & "include folders you navigate to"

- **Add Folder** (the `+`): existing `.folder` picker → persist a root bookmark in `BookmarkStore` → insert a `library_root` → kick an initial scan.
- **Auto-register navigated folders:** when a user opens a folder through the normal flow ([`FolderPicker`](../../../EchoCore/Utilities/FolderPicker.swift) → `loadFolder`), also register it as a `library_root` (if not already one). This delivers the owner's "include any folders navigated to in the picker" requirement — every folder you've touched becomes re-scannable, with its recursive grant already captured.
- **Manage roots** screen: list roots with `last_scanned_at`, per-root Rescan, and Remove root. On removal the user chooses: **forget its books** (default — drop their library rows after a study-data warning) or **keep** them, in which case Echo mints a per-book bookmark from the still-live root grant *before* releasing the root, so each kept book becomes an openable standalone entry (`source_root_id` cleared).

## 12. Derived status axes

- **Study status** (Not started / In progress / Finished) — from existing playback position + finished state per book. No new storage.
- **Processing status** — derived: **aligned** if the book has alignment anchors (beyond the trivial default pair); **narrated** if it has `narration_voice` tracks / `source_type` indicates synthesis; **transcribed** if a transcription row exists. A book can be several at once; the dot shows the highest-value state, the drill-down lists each.
- **`author_sort`** — best-effort: trim, collapse `"Last, First"` → `"First Last"`, lowercased grouping key; display uses the raw `author`. Mark as overridable in a later phase (no manual-edit UI this phase). Cleans up the obvious "Tolkien, J.R.R." vs "J.R.R. Tolkien" split without a full author table.

## 13. Scope boundaries & platform

**In (Phase 1, iOS):** audio-bearing books; the six axes; Add Folder + Rescan + auto-registered roots; unified ABS books; smart landing; hide-unavailable.

**Out (this phase):**

- Auto-adding document-only EPUB/MD/TXT during a scan (companion EPUBs beside audio still associate via existing logic). A "scan documents too" toggle is a later option.
- Live folder-watching (iOS can't; macOS `DispatchSource`/`FSEvents` is a later, Mac-only phase).
- **macOS UI.** `LibraryService` / `LibraryScanner` / `BookmarkStore` are built shared-ready, but the Mac surface + [`MacPlayerModel`](../../../Echo%20macOS/) wiring (which lacks ABS today) is a fast-follow — flag **cross-platform-parity-reviewer** when it lands.
- Splitting `topics_json` into separate genre/tags/series columns (a bigger migration; revisit if faceting demands it).

## 14. Testing strategy

- **`LibraryService` + `LibraryScanner`** against `DatabaseService(inMemory:)` and **temp directories on disk** (plain file URLs — no security scopes needed in tests): discovery, dedup-by-id, shallow insert (`index_state = 0`), `last_seen_at`/`is_available` refresh, known-but-absent → hidden, author/topic grouping, sort, `author_sort` normalization, processing-status & study-status derivation.
- **`BookmarkStore`** — file-backed test instance: multi-record store/restore, root-covers-children resolution, stale-bookmark → unavailable.
- **`SchemaV27Tests`** — migration applies cleanly on a V25 DB, new columns/table present, existing rows default sanely, no re-import/re-align triggered.
- Run via `make build-tests` once then `make test-only FILTER=EchoTests/<Suite>` (remember `CODE_SIGNING_ALLOWED=NO`). UI tests stay excluded.

## 15. Documentation impact

Per the project's doc-sync rule, on implementation: **ARCHITECTURE.md** gains a "Library" subsystem section (the launcher layer, the V27 schema, the scan pipeline, the access model); **README.md** gains the feature; **ROADMAP.md** moves it from idea → shipped; **CHANGELOG** entry. Run the **doc-sync** skill before the PR.

## 16. Open questions / future phases

1. **Cover regeneration** — generated placeholders at display time vs. caching them; and refreshing covers when a book is later fully imported.
2. **Author table** — promote `author_sort` to a real normalized author entity if "by Author" proves messy at scale.
3. **Genre vs tags split** — only if users want true genre faceting.
4. **macOS Library** — the fast-follow, including whether to bring ABS to `MacPlayerModel` at the same time.
5. **Document-only books in scans** — opt-in toggle.
6. **Live watching on macOS** — `DispatchSource` once the Mac surface exists.
