# Auto-Export Study Captures to Folder — Design

- **Status:** Approved design (implementation plan: [`2026-07-02-auto-export-to-folder.md`](../plans/2026-07-02-auto-export-to-folder.md))
- **Date:** 2026-07-02
- **Author:** Dan Fakkeldy (with Claude)
- **Branch base:** `nightly` (`feature/auto-export-folder-spec` cut from `origin/nightly` @ `24610794`)
- **Origin:** Owner request — "Auto copy notes/bookmarks to a folder of choice (MacroMark, in my case) for ingestion there." Echo pushes Markdown mirrors of study captures into a user-picked folder (typically an iCloud Drive folder) so an external second-brain pipeline can ingest them on the Mac.

## Context

Echo already renders study material as Markdown: [`StudyNotesExportService`](../../../EchoCore/Services/StudyNotesExportService.swift) produces an Obsidian-compatible per-book bundle (and a full-library zip) from bookmarks, notes, and flashcards, fed by [`StudyNotesExportDatabaseSource`](../../../EchoCore/Services/StudyNotesExportDatabaseSource.swift). But that export is **manual and share-sheet-oriented**: the user has to remember to run it, and the output is a zip meant for one-off handoff.

This feature makes the export **automatic and continuous**: when a study capture is created or edited, Echo re-exports the affected book's Markdown into a folder the user picked once. If that folder is in iCloud Drive, the files appear on the Mac without any further action — which is the whole point: downstream tooling (for Dan, a future MacroMark ingestion watcher) can consume them from there.

What already exists and is reused, not reinvented:

- **Markdown rendering + DB source** — `StudyNotesExportService` / `StudyNotesExportDatabaseSource` (per-book bookmarks, notes, flashcards, chapters).
- **Security-scoped folder grants** — [`LibraryAccess`](../../../EchoCore/Services/Library/LibraryAccess.swift) (make/resolve bookmarks, `#if os(macOS)` `.withSecurityScope` handling) and the `library_root.bookmark BLOB` persistence precedent from Schema V27 (local-library design §6, confirmed in the shipped `Schema_V27.swift`).
- **Capture write paths all land in GRDB** — bookmarks mirror through [`BookmarkStore`](../../../EchoCore/Services/BookmarkStore.swift) → `BookmarkDAO`; notes via `NoteDAO`; flashcards via `FlashcardDAO`. This includes watch-originated bookmarks (`WatchCommandRouter`) and widget/Siri-staged bookmarks (drained in `RootTabView`), so a database-level trigger observes **every** capture path without touching call sites.
- **Settings IA** — the intent-based root settings from the settings-cleanup design already has a **Study & Notes** section (`SettingsView.swift`, `SettingsStudyRows`), which is where this feature's controls live.

## Hard platform constraints (verified against the local-library design)

1. **iOS cannot watch folders.** Echo must **push** writes on its own events. Any folder-watching/ingestion on the Mac side is a **future MacroMark feature and is entirely out of scope here** — this spec must not promise or depend on MacroMark-side behavior that does not exist yet.
2. **Folder access requires a security-scoped bookmark** from a folder picker (`fileImporter`/`UIDocumentPickerViewController` with `.folder` on iOS; `NSOpenPanel` on macOS), persisted and re-resolved across launches, with stale-bookmark refresh and unresolvable-bookmark re-prompt.
3. **The destination will often be an iCloud Drive folder.** Writes must tolerate iCloud materialization quirks and must never block the UI. This design sidesteps the worst quirk entirely by **never reading destination files** (see §Write semantics).

## Goals

1. When auto-export is enabled and a destination folder is set, every created/edited note, bookmark, and flashcard is reflected in Markdown files in that folder within seconds — without user action.
2. Exports are **idempotent and deduplicatable**: re-exports never duplicate captures, and each capture carries a stable ID an external ingester can key on.
3. Captures are never lost: failures queue durably and retry; the database remains the source of truth and any state can be re-exported at any time.
4. Capture UX and playback are never blocked or interrupted by export activity or export failures.
5. Controls live in Settings ▸ Study & Notes: an enable toggle, a folder row, and a quiet status line.
6. The engine is cross-platform (`EchoCore`/`Shared`; `LibraryAccess` already branches bookmark options per platform). The v1 **Settings surface ships on iOS only** — see Non-Goals for why macOS trails.

## Non-Goals

1. **No Mac-side folder watching or ingestion.** That is MacroMark's planned post-launch companion; Echo only writes files. Referred to below as "future MacroMark ingestion" and never assumed.
2. **No MacroMark parsing logic** in Echo. Echo defines a stable file contract (below); the ingester is free to parse it later.
3. **No two-way sync.** Echo never reads, merges, or reconciles destination files. Edits made to exported files are overwritten by the next export of that book.
4. **No export of audio or image assets.** Flashcard audio snippets, bookmark voice memos, and bookmark photos are represented as text + metadata only in v1 (the manual zip export still carries assets). See §What exports.
5. **No daily-note append format** in v1 — considered and rejected, not deferred (see §File layout).
6. No change to the existing manual per-book / all-books export flows.
7. **No macOS Settings surface in v1** — a deliberate fast-follow (the local-library precedent). The macOS target has no `StoreManager`/paywall surface today, so an ungated macOS toggle would silently bypass the recommended Pro gate. The engine, schema, and renderer are macOS-ready; the pane (folder row via `NSOpenPanel` in `MacStudySettingsPane`) lands together with the macOS entitlement story.

## Current project constraints

- Worktree base: `origin/nightly` @ `24610794`; schema migrations run through **`v33_study_plan_card_pacing`**, so this feature claims **Schema V34** (`v34_study_auto_export`). Re-confirm `v34_*` is still free against `Shared/Database/DatabaseService.runMigrations` before writing the migration — version numbers on `nightly` are contended (V33 was claimed between this spec's research and drafting).
- Swift 6 language mode with MainActor default isolation; concrete-type + constructor/closure injection following `DatabaseService(inMemory:)`; **no protocols without a real second implementation or a genuinely wired-in test double** (CODE_AUDIT §10.1 history).
- No third-party frameworks. Swift Testing for tests (`make build-tests`, `make test-only FILTER=EchoTests/<Suite>`).
- Feature/docs PRs target `nightly`.

## Approved decisions

| # | Decision | Choice |
|---|---|---|
| 1 | File layout | **Per-book mirror files** in an Echo-owned subfolder; daily-note append rejected (see §File layout) |
| 2 | Grant + queue persistence | **GRDB** (Schema V34), following the `library_root.bookmark BLOB` precedent; the enable toggle lives in `SettingsManager` (UserDefaults) like every other preference |
| 3 | Trigger mechanism | **GRDB `DatabaseRegionObservation`** on the `note`, `bookmark`, and `flashcard` tables — one choke point covers phone UI, watch, widget/Siri, and macOS write paths |
| 4 | Write cadence | Debounce **5 s** after the last capture change; immediate flush on scenePhase `.background`/`.inactive`; full baseline export when the feature is enabled or the folder changes |
| 5 | Idempotency | Deterministic rendering + stable capture-ID markers + SHA-256 skip-if-unchanged; whole-file rewrite, never append |
| 6 | Failure handling | Persisted per-book dirty flags act as the outbox; errors surface only as a Settings status line; capture/playback UX never interrupted |
| 7 | Gating | **Auto-export is an Echo Pro feature; manual export stays free — ⚠️ Dan ratifies** (see §Settings & gating) |
| 8 | Audio-snippet cards | Text + metadata only in v1; the snippet's existence is noted in the entry |

## Architecture

Four new units plus two small extensions, all following the concrete-injection conventions in `ARCHITECTURE.md`:

```
capture writes (UI / watch / widget / macOS)
        │  (NoteDAO / BookmarkDAO / FlashcardDAO inserts & updates)
        ▼
GRDB commit ──▶ DatabaseRegionObservation ──▶ AutoExportService (@MainActor @Observable)
                                                │  mark book dirty (study_export_state)
                                                │  debounce 5 s / flush on background
                                                ▼
                                export pass (async; file IO detached off-main)
                                       ├─ StudyNotesExportDatabaseSource  (reads captures)
                                       ├─ AutoExportMarkdown              (pure renderer)
                                       ├─ StudyAutoExportDAO              (destination + state)
                                       └─ LibraryAccess                   (bookmark resolve)
                                                ▼
                              <picked folder>/Echo Study Notes/<Title>-<book_key>.md
```

- **`AutoExportService`** (`@MainActor @Observable final class`, `EchoCore/Services/AutoExportService.swift`) — owns the observation, debounce, dirty-set, and export pass. Constructor-injected with `DatabaseService`, an `isEnabled: () -> Bool` closure (reads `SettingsManager`), and a clock/debounce override for tests. Exposes `lastExportAt`, `needsFolderRepick`, `lastErrorSummary`, `destinationDisplayPath` for the Settings row. The export pass is async main-actor work in small per-book units — the same isolation every other DB consumer uses under the project's MainActor default isolation; SQLite reads and rendering are fast and SHA-skipped — while the only calls that can stall, `NSFileCoordinator` file IO against an iCloud folder, run inside detached tasks off the main thread.
- **`AutoExportMarkdown`** (pure `enum` with static functions, `EchoCore/Services/AutoExportMarkdown.swift`) — deterministic Markdown rendering and file naming. Same testability shape as `LibraryAccess`: no state, plain values in/out.
- **`StudyAutoExportDAO`** (`Shared/Database/DAOs/StudyAutoExportDAO.swift`) — reads/writes the two V34 tables below, in the `LibraryRootDAO` style.
- **Schema V34** (`Shared/Database/Migrations/Schema_V34.swift`) — two tables, strictly additive.
- **Extensions:** `StudyNotesExportService.Note`/`.Card` gain `var id: String? = nil` and `.Book` gains `var author: String? = nil` (defaulted — the manual export path is unaffected); `StudyNotesExportDatabaseSource` populates them from the records it already reads.

Why a **sibling service** instead of growing `StudyNotesExportService`: the existing service is a pure renderer for the manual share-sheet flow (temp dirs, asset copying, zips). Auto-export has a different lifecycle (long-lived, observing, stateful) and a different output contract (deterministic single files, no assets). Sharing the *data source* and *model structs* but not the renderer keeps both paths independently simple — and the manual path untouched.

## Folder picking & persistence

**Picker flow.**

- **iOS:** the folder row in Settings ▸ Study & Notes presents SwiftUI `.fileImporter(isPresented:allowedContentTypes: [.folder])`. On pick: `startAccessingSecurityScopedResource()` → `LibraryAccess.makeBookmark(for:)` → persist → `stopAccessingSecurityScopedResource()`. (The existing `FolderPicker` utility opens many content types for book import; a folder-only `fileImporter` is the simpler fit here.)
- **macOS (fast-follow, documented now so the contract is fixed):** the equivalent row in `MacStudySettingsPane` runs `NSOpenPanel` (`canChooseDirectories = true, canChooseFiles = false`). `LibraryAccess` already branches to `.withSecurityScope` bookmark options on macOS, so the engine needs no changes when the pane lands.

**Where the bookmark is stored: GRDB, not UserDefaults.** Schema V27 established that folder grants live in the database (`library_root.bookmark BLOB`); the export destination is the same class of data — a persistent folder grant plus associated machine state — and storing it beside the outbox keeps updates transactional. (The older Keychain slot in `Persistence.saveBookmark` is a single-purpose "restore last book" pointer that predates the library work; the library precedent is the one to follow. UserDefaults is explicitly avoided for bookmark data per the audit note in `Persistence.swift` §6.2.)

**Schema V34** (strictly additive; no changes to shipped migrations):

| Table | Columns |
|---|---|
| `study_export_destination` | `id TEXT PRIMARY KEY CHECK (id = 'default')`, `bookmark BLOB NOT NULL`, `display_path TEXT NOT NULL`, `needs_repick INTEGER NOT NULL DEFAULT 0`, `added_at TEXT NOT NULL` |
| `study_export_state` | `book_id TEXT PRIMARY KEY`, `file_name TEXT`, `dirty INTEGER NOT NULL DEFAULT 1`, `content_sha256 TEXT`, `last_exported_at TEXT`, `last_error TEXT` |

A `CHECK (id = 'default')` single row models "one destination" honestly; if multiple destinations are ever wanted, the table shape already fits.

**Resolution & staleness on every export pass:**

1. `LibraryAccess.resolveURL(from:)` on the stored bookmark.
2. Resolves with `isStale == true` → the folder moved or was renamed; the URL still works. Re-mint the bookmark from the resolved URL (`LibraryAccess.makeBookmark`), overwrite the stored blob and `display_path`, continue. **Folder moves/renames are self-healing and invisible to the user.**
3. Fails to resolve (folder deleted, iCloud account signed out, permission revoked) → set `needs_repick = 1`, skip the pass. Dirty flags keep accumulating; nothing is lost. The Settings row shows "Folder unavailable — tap to re-select" and the toggle stays on. Picking a new folder clears `needs_repick`, marks **all** books dirty, and triggers a full baseline export into the new folder.

`startAccessingSecurityScopedResource()` / `stop…` bracket each export pass (matching the `SecurityScopeManager` discipline of balanced grants; the pass is short-lived, so a transient grant per pass — not a held slot — is the right shape).

## What exports

All three capture types, per book, rendered from the same DTOs the manual export already uses:

| Capture | Fields exported | Source |
|---|---|---|
| **Note** (brain-dump) | id, text, media timestamp (if any), created-at | `NoteDAO` via `StudyNotesExportDatabaseSource.notes(for:)` |
| **Bookmark** (incl. voice/photo bookmarks' text) | id (UUID), title, note text, timestamp; voice-memo/photo presence noted as text. **Location fields (`latitude`/`longitude`/`placeName` from context memory) are deliberately NOT exported** — plaintext files in a synced folder are the wrong place for location traces | `BookmarkDAO` via `…bookmarks(for:)` |
| **Flashcard** (FSRS, incl. cloze) | id, front, back, tags, timestamp, end-timestamp, created-at; attached audio-snippet presence noted as text | `FlashcardDAO` via `…cards(for:)` |

**Audio-snippet cards: text + metadata only in v1.** A card with attached media renders a `- Media: <name> (attached in Echo; not exported)` line instead of copying the asset. Same for bookmark voice memos and photos. Rationale: assets make writes non-atomic (multi-file), bloat iCloud sync, and the ingestion use case is text. The manual zip export remains the asset-bearing path. Asset export can be a v2 format option if ingestion ever wants it.

**Chapter attribution** is derived at render time: the last chapter whose `startSeconds <= capture timestamp` (chapters from the existing `chapters(for:)` source). Captures without a timestamp get no chapter line.

**Deep links:** among capture types, Echo's `echoaudio://` scheme currently has a route for **bookmarks only** (`echoaudio://open/bookmark/<uuid>`, parsed by `PlayerDeepLink`; its other routes cover playback and settings navigation). Bookmark entries carry that link; notes and cards get **no** link in v1 because no route exists for them — adding `echoaudio://…/note/<id>` / `…/card/<id>` routes is a natural follow-up, noted in §Open questions. (The spec does not fabricate links that would 404.)

### File format (the contract a future MacroMark ingester can rely on)

One file per book. UTF-8, LF line endings, YAML frontmatter, HTML-comment capture markers. **Deterministic**: identical database state renders byte-identical files (no export timestamps inside the file — the filesystem mtime carries recency), which is what makes skip-if-unchanged and idempotent re-export trivial.

File-level frontmatter carries the book identity; per-entry lines carry capture metadata (this is where the "book title, author, chapter, timestamp, capture type, deep link" keys live — book-level keys once per file, capture-level keys once per entry):

```markdown
---
type: echo-study-export
version: 1
book: "The Field Guide to Tides"
author: "M. Ostrander"
book_key: 3f2a9c1d
---

# The Field Guide to Tides

## Bookmarks

<!-- echo:bookmark 7C4A8D09-1E4B-4F6A-9C0D-2B5E8A7F3C11 -->
### 00:41:12 — Spring tide mechanics
- Type: bookmark
- Chapter: 2. Why Two Tides a Day
- Open in Echo: echoaudio://open/bookmark/7C4A8D09-1E4B-4F6A-9C0D-2B5E8A7F3C11
- Voice memo: attached in Echo (not exported)

> Alignment of sun and moon stacks the bulges — check against the harbor tables.

## Notes

<!-- echo:note note-8f31c2 -->
### 00:12:40 — Note
- Type: note
- Chapter: 1. Reading the Water
- Created: 2026-07-01T20:58:31Z

> Neap vs spring: remember it as "neap = nipped range".

## Flashcards

<!-- echo:card card-b04e77 -->
### 00:58:03 — Flashcard
- Type: flashcard
- Chapter: 3. Currents and Slack
- Created: 2026-07-01T21:40:12Z
- Tags: tides, vocabulary

**Q:** What is slack water?
**A:** The short window when tidal current reverses and flow is near zero.
```

- **Stable capture IDs**: each entry is preceded by `<!-- echo:<type> <id> -->` using the capture's database primary key (`Bookmark.id` UUID; `note`/`flashcard` string ids). An ingester deduplicates on these; Echo's own idempotency doesn't depend on parsing them (whole-file rewrite).
- **`book_key`** = first 8 hex chars of SHA-256 of the `audiobook.id` (the normalized folder-URL string). It appears in the frontmatter *and* the filename, giving the ingester a stable book identity that survives book-title edits — and keeps the raw device path out of the file.
- **Filename**: `SafeFileName.sanitizeForFilename(title)-<book_key>.md`, e.g. `The Field Guide to Tides-3f2a9c1d.md`. If a book's title changes, the new render targets the new name; the previously recorded `file_name` in `study_export_state` is deleted from the destination in the same pass (safe because Echo owns everything inside its subfolder — see below).
- **Escaping**: entry text passes through the same `inlineMarkdown` escaping the manual export uses; frontmatter strings are double-quoted with `"` escaped.

## File layout — decision

**Chosen: per-book mirror files, written into an Echo-owned `Echo Study Notes/` subfolder of the picked folder.**

The alternative was MacroMark-style daily notes (one `YYYY-MM-DD.md` per day, captures appended). Comparison on the four criteria:

| Criterion | Per-book mirror (chosen) | Daily-note append |
|---|---|---|
| **Ingestion simplicity** | Ingester scans a folder of self-describing files; stable `book_key` + capture IDs; "file = current truth for that book" is the simplest possible contract | Matches MacroMark's daily-note shape, but the ingester must handle captures *edited after export* (already-appended lines go stale) and dedup across days |
| **iCloud merge conflicts** | Echo is the only writer of its files; whole-file atomic replace; worst case (two Echo devices) is last-writer-wins of equivalent mirrors | Appending means read-modify-write of files that iCloud may not have materialized and that other actors (MacroMark itself writes daily notes!) may be mutating concurrently — the classic conflict generator |
| **Idempotent re-export / dedup** | Free: deterministic render + rewrite; no parsing of existing files ever | Requires parsing every target file for existing capture IDs before appending; a failed half-append corrupts the dedup basis |
| **Human readability** | Strong: one tidy study sheet per book, mirroring the manual export users already know | Interleaves books chronologically; edits scatter as re-appends |

The decider is the combination of rows 2 and 3: **append requires reading destination files, and reading iCloud files that may not be materialized (or that MacroMark is simultaneously writing) is exactly the failure mode this feature must avoid.** The mirror model never reads the destination at all — writes are fire-and-forget atomic replaces — which collapses the iCloud risk surface to almost nothing.

Daily-note append is **not** offered as a format option: it would drag in the read-modify-write machinery (file parsing, append journals, conflict handling) that the mirror model exists to avoid, so it fails the "only if it costs almost nothing" bar. If future MacroMark ingestion genuinely wants daily notes, the right place to produce them is the ingester itself — it can trivially project per-book mirrors into its own daily notes on the Mac, where it owns those files. This split (Echo owns book mirrors, the future MacroMark ingester owns whatever it derives from them) is the honest contract while the ingester doesn't exist yet.

**Why a subfolder** (`Echo Study Notes/`): Echo must delete/rename its own files when book titles change — safe only inside a folder Echo wholly owns. It also keeps Echo's output visually separate from whatever else lives in the picked folder (e.g. MacroMark's own daily notes), and a recursive ingester finds it either way.

## Write semantics

**Triggers.**

1. **On capture (create/edit):** `DatabaseRegionObservation` on `note`, `bookmark`, `flashcard` fires on commit → the service marks the affected books dirty in `study_export_state` (dirty flags are *persisted*, so a kill before export loses nothing) → a **5-second debounce** coalesces bursts (typing edits, multi-card imports) → export pass. Region observation doesn't say *which* rows changed; the pass re-derives "books with captures" cheaply and re-renders dirty ones — correctness comes from re-rendering, not change tracking.
2. **On session end:** scenePhase `.background`/`.inactive` (the same `RootTabView` hook that persists navigation state) → flush immediately, bypassing the debounce, so captures land before iOS suspends the app. In-app book swaps need no dedicated hook: any pending debounce fires within 5 s regardless of which book is loaded, because the pass exports *dirty books*, not *the current book*.
3. **On enable / folder pick / re-pick:** mark all books that have any captures dirty → full baseline export.
4. **On becoming active:** if dirty rows or `last_error`s exist (a previous pass failed or the app was killed mid-debounce), run a pass.

**The export pass** (single-flight; a trailing run is scheduled if triggers arrive mid-pass):

1. Resolve destination (§Folder picking). Unresolvable → `needs_repick`, stop.
2. `SELECT` dirty books. For each: read captures via `StudyNotesExportDatabaseSource`, render with `AutoExportMarkdown`.
3. **Skip-if-unchanged:** compare the render's SHA-256 against `content_sha256`; identical → clear dirty, done (no write, no iCloud churn).
4. **Atomic write:** ensure `Echo Study Notes/` exists; write via `NSFileCoordinator` (`.forReplacing`) + `Data.write(to:options:.atomic)` — temp-file-and-rename within the destination volume, so the ingester never sees a half-written file. If `file_name` changed (title edit), delete the old file inside the subfolder in the same coordinated block.
5. Per book on success: `dirty = 0`, record `file_name`, `content_sha256`, `last_exported_at`, clear `last_error` — in one transaction.
6. Per book on failure: keep `dirty = 1`, record `last_error`. **A failing book never blocks other books' exports.**

**Append vs rewrite: always rewrite.** A book's file is a *mirror* of database state, not a log. Every mention of "export" above means "atomically replace the whole file". This is what makes deletes and edits propagate, re-exports idempotent, and destination reads unnecessary.

**Never blocks UI:** observation fires off the main queue; the pass itself is async main-actor work in small per-book units (reads and renders are fast, unchanged books SHA-skip to zero IO), and the `NSFileCoordinator` writes/deletes — the only calls that can stall on iCloud — run inside detached tasks off the main thread. Concurrency: `Task.sleep(for:)` debounce, structured tasks, no `DispatchQueue`/semaphores (project rule).

**Multi-device note:** if two devices export the same book to the same folder, files are last-writer-wins mirrors of each device's local DB — equivalent content when study data is in sync, and capture-ID markers keep any downstream dedup safe. Accepted for v1; not a data-loss risk (the DB is the source of truth, files are projections).

## Failure handling

| Failure | Behavior | Surfaced? |
|---|---|---|
| Folder unreachable / bookmark unresolvable | `needs_repick = 1`; passes stop; dirty flags accumulate | Settings row: "Folder unavailable — tap to re-select". Nothing modal, nothing during playback |
| Bookmark stale (folder moved/renamed) | Re-mint bookmark, update `display_path`, continue | No — self-healing |
| Write error (disk full, iCloud IO error, permissions) | Book keeps `dirty = 1` + `last_error`; retried next trigger/foreground | Settings row status line only ("Last export failed — will retry"), after retries also fail |
| iCloud not materialized | Cannot affect us on reads (we never read destination files); writes of new/replaced files do not require materialization; transient IO errors fall into the write-error path | No |
| App killed mid-debounce | Dirty rows are persisted; exported on next launch's active-pass | No |
| Book deleted from Echo | Its file is removed on the next pass (mirror semantics); `study_export_state` row cleared | No |

Principles: **never lose a capture** (the DB is canonical; the outbox is a persisted dirty-set, not a copy of data — there is nothing *to* lose), **never interrupt capture or playback UX** (no alerts, no sheets; all status is passive, in Settings), and **fail per-book, not per-pass**. `os.Logger` (`Logger(category: "AutoExport")`) records failures for diagnostics.

## Settings & gating

In Settings ▸ Study & Notes (per the settings-cleanup IA), rendered as native `Form` rows via a new `AutoExportSettingsRows` view:

- **Toggle** — "Auto-Export Study Notes". Backed by `SettingsManager.studyAutoExportEnabled` (UserDefaults, default `false`, key registered like every other setting).
- **Folder row** — shows `display_path` (e.g. "iCloud Drive ▸ MacroMark"); tap to pick/change via `fileImporter`. Shows the re-pick state when `needs_repick`.
- **Status footer** — "Last export: 2 min ago" / "Waiting for folder" / "Last export failed — will retry". Passive text only.
- **macOS:** deferred to the fast-follow (Non-Goals #7).

**Gating — ⚠️ Dan ratifies before implementation:** Proposed: **auto-export is an Echo Pro feature; the existing manual per-book/all-books export stays free and unchanged.** Automation-on-top-of-a-free-feature is a natural Pro line, and it grandfathers the manual flow that already shipped free — but this is an entitlement decision, so it ships only with Dan's explicit sign-off on this section. Mechanics: non-Pro users see the toggle; enabling routes through the existing `StoreManager.isPro` check → `PaywallView` (the established pattern), and the engine's enabled check also includes the entitlement — so if Pro lapses, exporting pauses quietly (no exported files are ever deleted).

## Testing strategy

All Swift Testing, in-memory/temp-dir seams, no mocks-for-mocks'-sake:

- **`SchemaV34Tests`** — migration applies on a pre-V34 DB; tables + defaults present; strictly additive.
- **`StudyAutoExportDAOTests`** — destination CRUD, single-row constraint, dirty-set lifecycle, success/failure recording (against `DatabaseService(inMemory:)`).
- **`AutoExportMarkdownTests`** — determinism (same input → identical bytes), frontmatter, capture-ID markers, chapter attribution, audio-card text-only line, escaping, filename stability under title collisions, `book_key` derivation.
- **`AutoExportServiceTests`** — end-to-end against an in-memory DB and a **temp-dir destination via a real `LibraryAccess` bookmark** (plain file URLs need no security scope in tests — the local-library suite already relies on this): dirty→export→clean, sha-skip (unchanged content leaves mtime alone), debounce coalescing (short test debounce injected), failure keeps dirty + records error, unresolvable destination sets `needs_repick`, title-rename removes the old file, book-delete removes the file.
- **Structural tests** (SettingsExtractionTests style) — Study & Notes exposes the toggle/folder/status rows; Pro gate present.

## Documentation impact

On implementation (doc-sync rule): **ARCHITECTURE.md** gains an "Auto-Export Study Captures" subsection (service, V34 schema, file contract); **CHANGELOG.md** Unreleased ▸ Added entry; **docs/guides/user-manual.md** gains a "Auto-export your study notes" section (and help paths if `HelpContent` references export). Run the **doc-sync** skill before the PR.

## Open questions / future phases

1. **Pro gating sign-off** — the one open decision; §Settings & gating. **Dan ratifies.**
2. Deep-link routes for notes/cards (`echoaudio://open/note/<id>`) so every entry can carry an "Open in Echo" link.
3. Asset export (voice memos, photos, audio snippets) as an opt-in v2 format extension.
4. Multi-destination support (the `study_export_destination` shape already allows it).
5. macOS Settings pane (`MacStudySettingsPane` + `NSOpenPanel`) — lands with the macOS Pro/entitlement story so the gate can't be bypassed from the desktop.
6. If future MacroMark ingestion defines a richer handshake (e.g. processed-file receipts), revisit — but the receipts would live on MacroMark's side; Echo's contract stays write-only.
