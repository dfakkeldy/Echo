# Library Edition Unification — one card per book

**Date:** 2026-07-10
**Problem:** The Library shows two entries per book — one for the `.m4b`, one for the
companion `.epub` — whenever the two were imported separately (different folders).
The user expects one entry per book.

## Root cause

Each import creates an `audiobook` row keyed by its folder URL:

- The m4b row gets title/author from audio tags (`LibraryScanner.readMetadata`).
- A separately-opened epub gets its own row via
  `TimelineIngestionService.persistAudiobook` with **title = folder/file name** and
  **author = nil**.

Schema V35 edition grouping was built to collapse such pairs into one card, but:

1. `LibraryService.refreshEditionGroups()` only runs during a root **rescan** (and
   `separateEdition`). Books that arrive via direct open/document import or ABS never
   get an `edition_group_id`, so `collapseEditionGroups` has nothing to merge.
2. `EditionMatcher` requires normalized **author AND title** to match. The epub row's
   nil author and folder-name title never match the m4b's tag metadata, so even a
   rescan won't pair them.

## Approaches considered

- **A. Make V35 grouping actually work (CHOSEN).** Presentation-layer collapse; both
  rows keep their ids, so playback progress, study decks (`targetMediaID` = folder
  URL), and alignment data are untouched. Retroactive, reversible via the existing
  "Separate This Edition" opt-out.
- **B. True merge** (import epub blocks under the m4b's id, delete the epub row).
  Rejected as default: destructive (orphans decks/progress keyed to the deleted row's
  id), requires file moves, and a wrong auto-match corrupts two books. Candidate for a
  later *explicit* user action ("Use as read-along text").
- **C. Metadata enrichment only.** Rejected: grouping still never fires for
  direct-import books.

## Design (approach A)

### 1. Author-tolerant `EditionMatcher`

Bucket identities by normalized title key. Within a title bucket:

- 0 or 1 distinct non-empty author keys → all members group (author-less rows join
  the authored ones). Group id stays `edition:<authorKey>|<titleKey>` using the
  bucket's non-empty author key (or empty).
- ≥ 2 distinct non-empty author keys → group per author key as today; author-less
  rows stay ungrouped (ambiguous — never guess between authors).
- Groups still require > 1 member.

### 2. OPF metadata enrichment (`EpubMetadataResolver` + `LibraryService`)

New `EpubMetadataResolver` alongside `EpubCoverResolver`, reusing the same OPF
location strategy (container.xml → rootfile, else first `*.opf`; zipped archive or
expanded dir; resolvable from an `audiobookID` folder URL). Parses `<dc:title>` and
`<dc:creator>` from the OPF `<metadata>` block.

`LibraryService.enrichTextOnlyBooks()` (async, off-main file I/O):

- Candidates: local rows (`sourceType != "audiobookshelf"`), text-only
  (`(fileCount ?? 0) == 0 && duration <= 0`), `author == nil`, not opted out.
- Best-effort: resolve OPF metadata from the row's id URL. On success set `author`;
  set `title` only when the persisted title still equals the folder-derived default
  (never clobber a meaningful title). Failures (sandbox scope, missing file) are
  skipped silently; an in-memory attempted set avoids re-parsing archives every
  reload in one session.

### 3. Regroup on shelf load

- `refreshEditionGroups()` becomes internal.
- `LibraryService.regroupForShelfLoad() async throws -> Bool` = enrich (best-effort)
  + refresh groups; returns whether any row changed.
- `LibraryViewModel.reload()` keeps its sync fetch, then kicks a single-flight async
  regroup pass and re-fetches sections/status/siblings when it reports changes.

### 4. Preserve enriched titles across reopens

`TimelineIngestionService.persistAudiobook` resets a local book's title to the folder
name on every open. For **audio-less** books with an existing row it now keeps the
persisted title (first insert still uses the folder name as placeholder). Audio books
and ABS behavior unchanged.

### 5. macOS parity

`MacLibraryBookRow` gains the same context menu as `LibraryCoverCell`: "Open
<sibling>" per edition (headphones/book icon) and "Separate This Edition". Without
this, collapse (which already applies on macOS) would make the epub unreachable
there. Uses the existing `LibraryViewModel.siblingEditions(of:)` /
`separateEdition(_:)` APIs.

## Error handling

- Enrichment is strictly best-effort: any file/parse failure leaves the row as-is.
- Regroup DB writes go through the existing DAO save path; failures surface in the
  existing `errorMessage` channel only when the sync fetch fails — background
  regroup failures log and leave the shelf unchanged.

## Testing

- `EditionMatcherTests`: author-less + authored same title → group; two authors +
  author-less same title → author-less ungrouped, authored pairs per author; two
  author-less same title → group; existing tests unchanged.
- `LibraryServiceTests`: end-to-end — text row (nil author, folder title) + audio row
  (tagged) collapse to one card after `regroupForShelfLoad()`; enrichment fills
  author/title from a `TestEPUBFixture` epub with OPF metadata; opt-out respected.
- `TimelineIngestionServiceTests` (or nearest suite): audio-less reopen preserves
  enriched title; audio book reopen still resets to folder title.
- `LibraryViewModelTests`: reload triggers regroup and re-fetches on change.

## Out of scope / follow-ups

- Explicit "merge into read-along" action (approach B as a user-triggered flow).
- ABS-side dedup beyond what title/author matching already provides.
- No schema migration: V35 columns suffice.

## Docs impact

ARCHITECTURE.md Library section (~lines 919–929): grouping now runs on shelf load
with OPF enrichment; matcher author-tolerance; macOS sibling menu.
