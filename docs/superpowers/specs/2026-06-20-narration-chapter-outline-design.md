# Narration Chapter Outline + Tap-to-Exclude — Design

**Date:** 2026-06-20
**Status:** Approved (pending spec review)
**Related:** TTS performance review (this session). Addresses the user-reported symptom
*"it seems to only show newly created chapters in the track list, rather than all the
rendered chapters."*

## Problem

For an on-device narration book (an audio-less study EPUB), the iOS playlist page shows
**no chapter list until playback starts**, and once it does, the play queue (`self.tracks`)
is built incrementally by the render loop — so it reflects *render progress*, not the
book's structure. A 20-chapter book playing chapter 3 shows ~5 entries, and a resume re-anchors
the list at the resume chapter (verified finding #5). The user perceives this as "only the
newly-created chapters show, not all of them."

Root cause: `model.chapters` is built from the *audio asset* (`ChapterLoadingCoordinator`
requires a loaded track), so a not-yet-rendered EPUB has no chapter rows at all. The full
EPUB structure is never surfaced before/while rendering.

## Goal

Show the **full chapter outline of the EPUB upfront** on the existing playlist page for a
narration book — every narratable chapter, independent of render progress — and let the user
**tap a chapter to exclude it from narration** (greyed out, never synthesized). This both
fixes the "incomplete list" complaint and gives the user control over what gets narrated
(saving synth time/battery on chapters they don't want).

## Non-goals

- No change to regular audiobook (M4B/folder) chapter behavior — the outline is narration-only.
- No new database table or migration. Exclusion reuses the existing `epub_block.is_hidden`
  column and the existing hide/unhide plumbing.
- Not removing the underlying render-ahead play queue (`self.tracks`); the outline is the
  user-facing chapter view layered over it.
- TOC-title enrichment beyond a best-effort heading/`"Chapter N"` is out of scope (follow-up).

## Design

### Outline source

The outline is the set of **narratable chapters**. The builder calls
`NarrationChapterPlanner.plan(from: allBlocks)` — passing **all** blocks, not `visibleBlocks` —
to get the chapter set and ordering. `plan` keeps any chapter that has text-bearing blocks and
does *not* itself filter on `is_hidden` (that filtering happens only when the caller pre-passes
`visibleBlocks`), so a fully-excluded chapter (text present but hidden) still appears in the
outline and can be re-included. The builder then annotates each chapter with `isExcluded` (every
block in the chapter is `is_hidden`) and `isRendered` (cache file exists).

**Chapter numbering & titles.** The outline numbers chapters by their **stable** position among
all narratable chapters (from `plan(from: allBlocks)`), so a number never shifts when the user
excludes/includes a chapter. Title is the chapter's first heading-block text when present, else
`"Chapter \(displayNumber)"`. Note: the render path computes its track titles from
`plan(from: visibleBlocks)` (visible-only numbering), so after an exclusion a rendered file's
"Chapter N" title can differ from the outline's stable number. Reconciling the render path onto
stable numbering is a small follow-up, not part of this change; the outline is the user-facing
list and is internally consistent.

### Exclusion mechanic (reuses existing `is_hidden` axis)

Excluding a chapter = marking all of that chapter's blocks `is_hidden = 1`. This already exists:
`AlignmentService.hideChapter(chapterIndex:reason:)` → `EPubBlockDAO.hideChapter(...)`. We add the
mirror `EPubBlockDAO.unhideChapter(chapterIndex:audiobookID:)` + `AlignmentService.unhideChapter`.

`NarrationChapterPlanner.plan` (fed `visibleBlocks` by the render loop) already drops hidden
blocks, so an excluded chapter is **never synthesized and never queued** — satisfying both
approved decisions:
- **Exclude before render:** the chapter is absent from the render plan → skipped entirely.
- **Exclude an already-rendered chapter:** its blocks go hidden → it drops out of the plan and
  the play queue on the next plan build; **the rendered file is left on disk** (no delete), so
  re-including is instant (no re-render). Mid-render exclusion also removes it from the live
  `self.tracks` queue if present.

`is_hidden` is already persisted, so exclusions survive relaunch and re-render with no new storage.

### Data model

A small view model type, built by the model, consumed by the view:

```swift
struct NarrationOutlineChapter: Identifiable, Equatable {
    let chapterIndex: Int      // raw EPUB index (stable identity, keys file + track)
    let displayNumber: Int     // 1-based position among narratable chapters
    let title: String          // first heading block's text, else "Chapter \(displayNumber)"
    let isExcluded: Bool       // all blocks hidden → not narrated
    let isRendered: Bool       // chapter file exists in the narration cache
    var id: Int { chapterIndex }
}
```

### Model API (PlayerModel, narration extension)

- `var narrationOutline: [NarrationOutlineChapter]` — computed/cached from the EPUB blocks +
  per-chapter hidden state + cache-file existence. Rebuilt on book load, after a render
  completes a chapter, and after a toggle.
- `func toggleNarrationChapterExcluded(chapterIndex: Int)` — flips the chapter's hidden state via
  `AlignmentService.hideChapter`/`unhideChapter`, removes it from the live queue if newly
  excluded, refreshes `narrationOutline`. `@MainActor`.
- `var isNarrationBook: Bool` — gates the outline UI (audio-less EPUB with on-device narration).

The outline build (block query → group by chapter → title/excluded/rendered) lives in a pure,
unit-testable helper (`NarrationOutlineBuilder`) taking blocks + a "file exists" closure, so it
can be tested without a player or filesystem — mirroring `NarrationChapterPlanner`.

### UI (PlaylistView)

For a narration book, render an **Outline** section (reusing the existing row visual language):
- Row = chapter title + state. Tapping the row toggles exclude/include (greying the row when
  excluded), mirroring the existing `chapterRowContent` "whole row toggles" pattern.
- A trailing play affordance for **rendered** chapters seeks/plays that chapter; pending
  (not-yet-rendered) chapters show a subtle "pending" state; excluded chapters show greyed with a
  speaker-slash glyph.
- Shown when `model.isNarrationBook`; the current audio-derived chapter/track modes are unchanged
  for regular audiobooks. This fills what is currently an empty playlist page pre-render.

## Edge cases

- **Mid-render exclusion:** if the excluded chapter is already in `self.tracks` (queued/rendered),
  remove it from the queue; if it is the *currently playing* chapter, advance to the next included
  chapter (degrade gracefully — do not stop playback).
- **Exclude-all:** if every chapter is excluded, narration has nothing to render — show the
  existing "No text to narrate" status instead of starting.
- **Re-include after relaunch:** unhidden chapter re-enters the plan; if its file still exists it
  is reused, else it renders on demand under the normal render-ahead policy.

## Testing

- `NarrationOutlineBuilder` (pure): full outline from mixed visible/hidden blocks; excluded
  chapters present-but-flagged; `isRendered` driven by the injected file-exists closure; title
  falls back to "Chapter N".
- `EPubBlockDAO.unhideChapter` round-trips with `hideChapter` (hide → unhide restores visibility).
- `NarrationChapterPlanner` already excludes hidden blocks (existing coverage) — add a test that a
  hidden whole chapter drops from `plan(from: visibleBlocks)`.
- Toggle behavior at the model layer where feasible without a live player.

## Affected files

- `EchoCore/Services/Narration/NarrationOutlineBuilder.swift` (new, pure)
- `EchoCore/Models/NarrationOutlineChapter.swift` (new) — or co-located with the builder
- `EchoCore/ViewModels/PlayerModel+Narration.swift` — `narrationOutline`,
  `toggleNarrationChapterExcluded`, `isNarrationBook`, live-queue removal
- `EchoCore/Services/AlignmentService.swift` + `Shared/Database/DAOs/EPubBlockDAO.swift` —
  `unhideChapter`
- `EchoCore/Views/PlaylistView.swift` — narration outline section + greying
- Tests: `EchoTests/NarrationOutlineBuilderTests.swift`, additions to block-DAO / planner tests

## Out of scope / follow-ups

- The resume-anchored play-queue reset (verified finding #5) is a separate, lower-priority polish;
  the outline makes it far less user-visible by surfacing the full structure regardless of queue
  state. Revisit only if still noticeable.
- Real TOC titles per chapter (vs. heading/`"Chapter N"`).
