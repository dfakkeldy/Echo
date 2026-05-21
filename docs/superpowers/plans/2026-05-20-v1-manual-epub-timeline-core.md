# V1 Manual EPUB Timeline Core Implementation Plan

> For Claude Code / implementation agents: read this after `README.md`,
> `ARCHITECTURE.md`, `CLAUDE.md`, and
> `docs/superpowers/specs/2026-05-18-epub-audio-alignment-design.md`.
> This is a planning artifact only; implement in small, testable stages.

## Summary

Build the V1 high-powered timeline around EPUB/audio alignment, not around
transcripts. The durable object model should be:

```text
EPUB block -> optional timestamp/range -> timeline item -> playback/feed interaction
```

Preserve the current `NowPlayingTab` player UX. Timeline work should live in
services, DAOs, and view models, with `TimelineTab` remaining a thin coordinator.

V1 is manual-first:

- Import EPUB structure into SQL.
- Estimate timestamps from chapters and duration.
- Let users create locked anchors.
- Interpolate timestamps between anchors.
- Hide EPUB sections omitted from the audiobook.
- Render dense feed items from SQL.

Whisper/enhanced transcript remains optional input, not the foundation.

## Architecture And Data Model

### Add `Schema_V5`

Register a new migration in `DatabaseService.runMigrations()` after V4.

Add table: `epub_block`

```text
id TEXT PRIMARY KEY
audiobook_id TEXT NOT NULL REFERENCES audiobook(id) ON DELETE CASCADE
spine_href TEXT NOT NULL
spine_index INTEGER NOT NULL
block_index INTEGER NOT NULL
sequence_index INTEGER NOT NULL
block_kind TEXT NOT NULL -- heading, paragraph, sentence, image
text TEXT
image_path TEXT
chapter_index INTEGER
is_hidden BOOLEAN NOT NULL DEFAULT false
hidden_reason TEXT
created_at TEXT
modified_at TEXT
```

Indexes:

```text
(audiobook_id, sequence_index)
(audiobook_id, chapter_index)
(audiobook_id, is_hidden)
```

Add table: `alignment_anchor`

```text
id TEXT PRIMARY KEY
audiobook_id TEXT NOT NULL REFERENCES audiobook(id) ON DELETE CASCADE
epub_block_id TEXT NOT NULL REFERENCES epub_block(id) ON DELETE CASCADE
audio_time DOUBLE NOT NULL
audio_end_time DOUBLE
anchor_kind TEXT NOT NULL -- point, chapterStart, chapterEnd
source TEXT NOT NULL -- moveToNow, searchResult, chapterBoundary, imported
note TEXT
created_at TEXT
modified_at TEXT
```

Indexes:

```text
(audiobook_id, audio_time)
(audiobook_id, epub_block_id)
```

Extend `timeline_item` with nullable columns:

```text
epub_block_id TEXT
timestamp_source TEXT -- none, estimated, interpolated, lockedAnchor, transcript
alignment_status TEXT -- unaligned, estimated, interpolated, lockedAnchor, omitted
alignment_confidence DOUBLE
```

Keep the existing `audio_start_time = -1` convention for untimestamped rows to
avoid breaking current UI logic.

## Core Services

### `EPUBImportService`

Responsible for app-side EPUB import.

Inputs:

```swift
audiobookID: String
epubURL: URL
chapters: [Chapter]
bookDuration: TimeInterval?
```

Responsibilities:

- Unpack EPUB into app-controlled storage.
- Parse OPF spine order.
- Parse XHTML into ordered blocks.
- Split text into paragraph-level blocks for V1; sentence splitting can be optional later.
- Extract image references.
- Copy images into app storage.
- Write `epub_block` records.
- Trigger timeline re-ingestion.

Storage rule:

```text
Application Support/EPUBAssets/<safeAudiobookID>/
```

All image paths stored in SQL must be real local file paths usable by:

```swift
UIImage(contentsOfFile:)
```

Do not store raw EPUB hrefs in `timeline_item.image_path`.

### `AlignmentService`

Responsible for manual alignment and timestamp interpolation.

Public operations:

```swift
moveBlockToCurrentTime(blockID: String, time: TimeInterval)
anchorSearchResult(blockID: String, time: TimeInterval)
anchorChapterStart(blockID: String, chapterIndex: Int, time: TimeInterval)
anchorChapterEnd(blockID: String, chapterIndex: Int, time: TimeInterval)
hideBlock(blockID: String, reason: String?)
unhideBlock(blockID: String)
recalculateTimeline(audiobookID: String)
```

Interpolation rules:

- Locked anchors always win.
- Blocks between two anchors interpolate linearly by `sequence_index`.
- Blocks inside a chapter with known chapter start/end but no manual anchors get `estimated`.
- Blocks outside known ranges remain `unaligned` with `audio_start_time = -1`.
- Hidden blocks become `alignment_status = omitted`, `is_enabled = false`, and are excluded from default feed queries.
- Recalculation updates affected `timeline_item` rows in one DB transaction.

### `TimelineIngestionService`

Replace timeline materialization currently embedded in `PlayerModel`.

Inputs:

```swift
audiobookID
chapters
epubBlocks
anchors
bookmarks
flashcards
plainTranscript?
enhancedTranscript?
```

Responsibilities:

- Materialize chapter rows.
- Materialize EPUB text/image rows.
- Materialize bookmarks/cards.
- Preserve source linkage through `source_table`, `source_rowid`, and `epub_block_id`.
- Prefer EPUB block sequence order for feed ordering.
- Prefer timestamp order only when rows are timestamped.

## Fix Existing Repo Issues First

### 1. Fix `PlayerModel.loadFolder()`

Current bug: SQL persistence happens before tracks are loaded.

New order:

```text
stop playback
start security scope
load tracks
set folderURL
persist audiobook + tracks to SQL
prepare playback
load transcript/enhanced transcript if present
ingest sparse/rich timeline
post timeline reload notification
```

Remove or replace the current comment about persisting before `folderURL`
changes. Timeline reload should be explicit, not an accidental side effect of
`folderURL`.

### 2. Call migration service at startup

In `Orbit_AudioBooksApp.init()`:

```text
create DatabaseService
assign to model
call MigrationService.migrateIfNeeded(database:)
```

### 3. Fix timeline load errors

`TimelineFeedViewModel` should expose:

```swift
private(set) var lastError: Error?
```

On DAO failure:

- Assign `lastError`.
- Log the error.
- Keep existing items when possible instead of replacing them with an empty feed.

### 4. Wire follow playback scrolling

`TimelineTab` must pass a real callback into `TimelineFeedCollectionView`.

Recommended design:

- Add `@State private var scrollTargetPosition: TimeInterval?`.
- `TimelineFeedViewModel.onScrollToPosition` updates that state.
- `TimelineFeedCollectionView.updateUIView` detects changes and calls
  coordinator `scrollTo(position:)`.

### 5. Fix filename safety

Create a shared helper:

```swift
SafeFileName.fromAudiobookID(_:)
```

Use it for:

- Chapter artwork cache filenames.
- EPUB asset folder names.
- Any future derived asset paths.

## Timeline UX Behaviors

### Feed states

Represent feed mode explicitly:

```swift
enum TimelineFeedMode {
    case followingPlayback
    case browsing
    case searchingToAnchor
    case editingAlignment(selectedBlockID: String)
}
```

Behavior:

- Playback tick in `followingPlayback` scrolls to the active timestamped item.
- User drag switches to `browsing`.
- `Go to Now` switches back to `followingPlayback` and scrolls to current playback time.
- VoiceOver disables automatic scroll, preserving current behavior intent.
- Optional setting: pause playback when the user manually scrolls away from Now.

### Context menu

For EPUB text/image blocks:

- `Play From Here` if timestamped.
- `Move to Now`.
- `Search Similar Text`.
- `Hide Omitted Text`.
- `Unhide` if hidden.

For chapter markers:

- `Set Chapter Start Here`.
- `Set Chapter End Here`.
- `Play From Chapter`.

For bookmarks/cards, preserve existing seek/review behavior.

### Search-to-anchor

Add a lightweight search sheet driven by `TimelineFeedViewModel`.

Search source:

- `epub_block.text`
- Filter hidden blocks unless "show hidden" is enabled.

Result tap:

```text
create locked anchor at current playback time
recalculate affected timeline rows
dismiss search
scroll selected block into view
```

## Enhanced Transcript Compatibility

Update `TranscriptService` so it can load both:

```text
<audio>.transcript.json
<audio>.enhanced.json
```

State should distinguish:

```swift
plainTranscription: [TranscriptionSegment]
enhancedTranscription: [EnhancedTranscriptionSegment]
```

If that state split is too large for V1, keep plain transcript in current state
and have `TranscriptService` return enhanced transcript directly to ingestion.

Important: enhanced transcript can enrich timeline rows, but EPUB import/manual
anchors must work without it.

## Test Plan

### Unit tests

Add tests for `AlignmentService`:

- Two locked anchors interpolate middle blocks.
- Moving an existing anchor updates affected rows.
- Blocks before first anchor stay estimated or unaligned according to chapter data.
- Hidden blocks are excluded from default feed.
- Locked anchors survive recalculation.

### EPUB import tests

Use a minimal EPUB fixture with:

- Two XHTML spine items.
- One heading.
- Two paragraphs.
- One image.

Assert:

- Stable block ordering.
- Correct `sequence_index`.
- Image copied to real local file path.
- Raw href is not stored in `timeline_item.image_path`.

### DAO tests

For `TimelineDAO`:

- Timestamped rows load by time window.
- Untimestamped EPUB blocks load by sequence.
- Hidden rows are excluded from normal feed.
- Mixed chapter/bookmark/EPUB rows sort predictably.

### View-model tests

For `TimelineFeedViewModel`:

- Playback update in follow mode emits scroll callback.
- User scroll changes mode to browsing.
- `goToNow()` restores follow mode.
- Search result anchoring calls alignment service and reloads items.
- DAO errors populate `lastError`.

### Regression tests

Cover the known issues:

- `loadFolder()` persists SQL after tracks load.
- `MigrationService.migrateIfNeeded` is called on startup.
- Enhanced transcript sidecar is discoverable.
- Follow playback callback scrolls collection view.
- Chapter artwork filename sanitizes `file://` IDs.
- EPUB images render from copied asset paths.
- Timeline DAO errors are not swallowed.

Verification commands:

```bash
xcodebuild test \
  -project "Orbit Audiobooks.xcodeproj" \
  -scheme "Orbit Audiobooks" \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
```

```bash
cd Tools/OrbitTranscriptionCLI && swift test
```

If `swift` or `xcodebuild` are unavailable, state that verification could not
be run in that environment.

## Implementation Order

1. Repair current timeline plumbing and regressions.
2. Add `Schema_V5`, records, and DAOs.
3. Add EPUB import and offline asset copying.
4. Add timeline materialization from EPUB blocks.
5. Add manual anchors and interpolation.
6. Wire feed states, context menu actions, and search-to-anchor.
7. Add enhanced transcript compatibility.
8. Add tests and update docs.

## Out Of Scope For V1

- Full automatic Whisper alignment.
- Simple player fork.
- Playlist editing redesign.
- Social/Twitter functionality.
- Cloud sync.
- Full word-level highlighting.
- Cross-device alignment sync.
- Mac-only alignment workflow as a requirement.

## Documentation Follow-Up

After implementation, update:

- `ARCHITECTURE.md`
- `README.md` timeline notes
- `docs/superpowers/specs/2026-05-18-epub-audio-alignment-design.md` if the app-side model diverges from the CLI-first design
