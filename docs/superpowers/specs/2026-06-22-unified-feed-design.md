# Unified Feed — Design Spec

**Date:** 2026-06-22
**Status:** Design approved (brainstorm), pending written-spec review → implementation plan
**Topic:** Merge the audio playlist, the EPUB reader, and the study timeline into one collapsible, heterogeneous "feed" surface; add session-scoped review.

---

## 1. Summary

Today Echo has three tabs — **Listen** (`.nowPlaying`), **Read** (`.read`, the EPUB reader), and **Study** (`.timeline`, a chronological chapters+bookmarks playlist). This spec collapses **Read + Study into a single surface**: one smooth, collapsible feed that *is* the table of contents (collapsed), the reader (expanded), and the study timeline (the items threaded through it). The only other primary surface remains the **now-playing audio screen**.

The feed is heterogeneous — a "Twitter-style" stream where every kind of content is a card anchored at its real position in the book: headings, paragraphs, images, bookmarks, anki cards, voice memos, notes. Filtering gains **two composable axes**: *content type* (Everything / Audio / Text / Pics / Bookmarks / Cards…) and *scope* (Whole book / Last session / a specific session). The session axis turns "I listened to something on my route" into "here's exactly what I covered and made, and where."

### Why this is feasible (the load-bearing facts)
- The reader is already a `UICollectionView` feed grouped **one section per chapter** ([ReaderFeedViewModel.swift](../../../EchoCore/ViewModels/ReaderFeedViewModel.swift)) — the right engine for a smooth collapsible stream. We **evolve it**, not replace it.
- The audio↔text mapping is already queryable: `epub_toc_entry.block_id` → `alignment_anchor.epub_block_id` ([AlignmentAnchorDAO.swift](../../../Shared/Database/DAOs/AlignmentAnchorDAO.swift)). A heading "has audio" is a query, not a new feature.
- A heterogeneous positioned stream already exists in the schema: [TimelineItem](../../../Shared/Database/TimelineItem.swift) `item_type` is already `textSegment | chapterMarker | imageAsset | bookmark | ankiCard`, each carrying `created_at` and an audio anchor.
- A per-heading exclusion primitive exists: `epub_block.is_hidden` (narration already respects it via `visibleBlocks()`).
- **Sessions are already recorded:** [PlaybackSessionRecorder.swift](../../../EchoCore/Services/PlaybackSessionRecorder.swift) + [PlaybackEventLogger.swift](../../../EchoCore/Services/PlaybackEventLogger.swift) are wired into the player ([PlayerModel.swift:936](../../../EchoCore/ViewModels/PlayerModel.swift)); tables `playback_session`, `playback_event`, and `session_location` exist ([Schema_V14.swift](../../../Shared/Database/Migrations/Schema_V14.swift)).

**No core schema change is required for the feed.** New columns/types are needed only for the additive pieces (voice-memo/note item types; possibly a session display cache) — see §10.

---

## 2. Goals / Non-goals

**Goals**
- One collapsible feed that serves as TOC, reader, and study timeline.
- Honest per-heading status: has-audio / no-audio (would be narrated) / has-cards / off.
- Per-heading off-switch that gates audio playback, narration, **and** flashcards consistently.
- Two-axis filtering (content type × session scope).
- Session review: "Last session" scope + a browsable Sessions list with GPS-aware recaps.
- iOS first; macOS parity afterward via the existing Mac reader feed.

**Non-goals (this initiative)**
- watchOS and Widget surfaces (no equivalent; explicitly out).
- Re-architecting alignment, narration, or the now-playing screen.
- New study/SRS behavior beyond surfacing existing cards in the feed.

---

## 3. The feed: TOC + reader + study timeline (one surface)

- **Collapsed** = the table of contents: top-level headings only, scannable.
- **Tap a chapter** (or **press play** on it) → it expands **in place** into the real reading content: text, with images inline where they occur.
- **The playing chapter auto-expands** and follows along (karaoke word highlight; grey = already read).
- **Tap any word** → playback jumps to that word.
- **Collapse-siblings behavior:** opening a chapter collapses others (or a sticky chapter header keeps context) so a long chapter doesn't bury the next heading — decide the exact behavior at plan time; default assumption is **auto-collapse other chapters, with a sticky header for the open one.**

**Approach decision:** evolve [ReaderFeedCollectionView.swift](../../../EchoCore/Views/ReaderFeedCollectionView.swift) / [ReaderFeedViewModel.swift](../../../EchoCore/ViewModels/ReaderFeedViewModel.swift) into the collapsible feed. Rejected alternative: a fresh SwiftUI `List` (loses collection-view performance, karaoke, and tap-to-seek; forces duplicate machinery).

---

## 4. Read model — what a row knows

A Swift assembler decorates each chapter/heading with **honest flags**, built over existing tables (no core schema change):

- `hasAudio` — **any** alignment anchor exists within the heading's **block range** (not a single lookup on the heading's own block).
- `hasNarration` — narrated/synthesized audio or synth anchor exists for the chapter.
- `hasCards` — a flashcard is anchored to the heading/chapter.
- `offState` — see §5.

> **Critical correctness note (the "has audio" lie):** Alignment usually anchors *content* blocks deep inside a section, not the title block. A naive `heading.blockID → anchor` lookup therefore paints fully-aligned chapters as "no audio." `hasAudio` **must** test for any anchor across the heading's block range (via `epub_block.chapter_index`, or a `sequence_index` window to the next sibling heading). This is the difference between the styling being trustworthy and being misleading.

Collapsed rows render from this decoration. Expanding streams that chapter's `TimelineItem`s in document/anchor order through the existing cell pipeline.

---

## 5. Gestures & the off-switch

| Gesture | Action |
|---|---|
| **Tap** chapter | Expand / collapse |
| **Tap** word (expanded) | Play from that word |
| **Long-press** chapter | Menu (the *only* place "off" lives) |
| **Swipe** chapter | Reserved (future: quick-bookmark) |

- **No checkbox column.** An **off** chapter simply **greys out**. Reclaims the whole left column for content.
- The **long-press menu** offers **"Turn off everywhere"** plus granular **Listen / Narrate / Cards** toggles. The granular toggles produce the "mixed" state.
- **"Off everywhere"** writes whichever flags apply: `isEnabled = false` on the mapped audio chapter (skips it in the playback queue) **and** `is_hidden = true` on the heading's blocks (no narration, no display, no cards once §7.1 lands).

---

## 6. Filters — two composable axes

1. **Content type** (chips): `Everything · Audio · Text · Pics · Pics+Audio · Bookmarks · Cards` (extensible). A predicate over the read-model flags / item types.
   - **Pics** keeps collapsible headings; images render inline in-context when expanded; the filter narrows revealed content to image-bearing material.
2. **Scope** (selector above the chips): `Whole book · Last session · Sessions…`. A predicate over the time/session window.

The axes **compose**: "Last session" × "Pics" = just the pictures from that drive. Building the filter model **two-dimensional from the start** (scope is a first-class dimension, not a retrofit) is an explicit design requirement even though only "Whole book" + "Last session" ship first.

---

## 7. Correctness fixes (behind the glass)

### 7.1 Flashcards must respect the off-switch (required)
[ChapterCardDrafter.swift](../../../Shared/Services/ChapterCardDrafter.swift) currently drafts cards from headings **without** checking `is_hidden`, so an "off" chapter would still generate cards — breaking the feature's own promise. Fix: add the `is_hidden` gate (or route through `EPubBlockDAO.visibleBlocks()`), with a test. Shippable independently in Phase 0.

### 7.2 Reconcile the two off-systems (required)
Audio uses `isEnabled` (UserDefaults / `PlaylistManifestService`); EPUB uses `is_hidden` (GRDB). Introduce a single **`OffState` resolver** so the feed reads *one* truth and the long-press menu writes the correct flag(s) per heading kind, instead of two persistence systems drifting. (Note: CloudKit sync of `is_hidden` synth anchors is a known leak area — see CODE_AUDIT §6.2 — keep it in view.)

---

## 8. Content types

Implemented first (already exist as data): **headings, paragraphs/sentences, images, bookmarks, anki cards.**

Added later as **two new `TimelineItem.item_type`s**: **voice memos** and **notes** (notes already have a `note` table from Schema_V2; voice memos are net-new capture + storage). The feed's cell registry must be **open/extensible** so new item types slot in without touching the core feed. Capture UI for memos/notes is its own slice (Phase 4) — no half-built capture riding along earlier phases.

---

## 9. Sessions (the session axis + review)

A **session** = one recorded `playback_session` (durational; start/end), with its `playback_event`s and `session_location` (GPS, **opt-in**).

- **"Last session" scope** — filters the feed to the most recent session's window: the EPUB/chapter range it covered + items `created_at` within it.
- **Sessions list** — a browsable history; each row recaps one session: when, where (route + miles, if location enabled), minutes listened, chapter range covered, and counts of bookmarks/cards/pics/notes. Tap a row → scope the feed to it.
- **Recap card** — shown atop a scoped feed (see mockup): when · where · listened · covered range · created items.

**Verification at plan time:** confirm exactly what `playback_session` / `playback_event` store (start, end, audiobook, and whether the **covered position range** is directly stored or must be reconstructed from events/`playback_state`), and how `session_location` rows associate to a session. The "covered range" derivation is the one place this could need a small addition.

---

## 10. Data model notes

- **Feed core:** no schema change. Reads `chapter`, `track`, `epub_block`, `epub_toc_entry`, `alignment_anchor`, `timeline_item`.
- **Sessions review:** reuses `playback_session`, `playback_event`, `session_location`. Possible additive: a denormalized per-session "covered range" / counts cache **only if** reconstruction is too costly for smooth scroll.
- **New item types:** voice-memo + note as `TimelineItem.item_type` values; voice-memo storage (audio file + row) is net-new.
- **Schema versioning caution:** migration version numbers currently collide across branches (memory notes V21–V23 in flight). Any new migration must claim the **next free version on `nightly` at implementation time** and ship a `SchemaVxxTests` — do not hard-code a number in this spec. (Use the `schema-migration-reviewer` before committing any migration.)

---

## 11. Risks & mitigations

| Risk | Mitigation |
|---|---|
| "Has audio" under-reports (anchors on content, not titles) | Range test for any anchor in the heading's block window (§4). |
| Two off-systems drift; "off" still plays/narrates | Single `OffState` resolver (§7.2); tests for each heading kind. |
| Flashcard gate bug ships the wrong promise | Phase 0 fix + test (§7.1) before any UI. |
| Alignment is optional & re-runnable (auto anchors deleted/re-inserted each run) | Feed observes recomputation; never caches stale `hasAudio`; re-align can flip a row's styling. |
| Degenerate books (audio-only no EPUB; EPUB-only no audio; imported m4b no EPUB) | Three explicit modes: chapters-only feed; all-text feed (narratable); plain chapter list. |
| Long expanded chapter buries next heading | Auto-collapse siblings + sticky chapter header (§3). |
| Smooth-scroll regressions with mixed cell types | Keep the `UICollectionView` engine; profile; reuse existing lazy cells. |
| Nav consolidation blast radius (Read+Study tabs, `BottomToolbarView` tab cycle, deep links) | Isolate to Phase 2; remap `PlayerDeepLink` targets; keep `.nowPlaying` untouched. |
| macOS divergence (separate `MacTOCTreeView` / tri-pane) | Reuse the same read model on macOS in a later phase. |
| Session "covered range" not directly stored | Verify at plan time; small additive cache only if needed (§9). |

---

## 12. Decomposition (phases)

This is a **program, not one PR.** The spec captures the full vision; implementation plans are written **one phase at a time.**

- **Phase 0 — Trust the data (no UI).** Honest `hasAudio` range query; flashcard `is_hidden` gate fix (§7.1). Safe, testable, shippable.
- **Phase 1 — Collapsible reader feed (iOS).** Collapsed = TOC; tap = expand; tap-word = seek; auto-collapse siblings + sticky header. Evolve the existing reader feed.
- **Phase 2 — Feed becomes the Study surface.** Bookmarks + cards inline; grey-out + long-press off menu + `OffState` resolver (§7.2); retire the chronological playlist; collapse Read + Study into one tab; remap deep links.
- **Phase 3 — Filters + session scope.** Two-axis filter model; content chips; images-in-context; **"Last session"** scope + recap card.
- **Phase 4 — New content types + capture.** Voice memos + notes as item types, with capture UI.
- **Phase 5 — Sessions list + macOS parity + doc-sync.** Browsable Sessions history; macOS reuse of the read model; update ARCHITECTURE.md / README.

**Recommended first plan:** Phase 0 + Phase 1 together (de-risk the data, then deliver the visible magic).

---

## 13. Open questions to resolve at plan time
1. Exact `playback_session` / `playback_event` columns and whether covered-range is stored or derived (§9).
2. Sticky-header vs accordion-collapse interaction details (§3).
3. Swipe gesture's eventual home (quick-bookmark?) — reserved, not specced here.
4. Next free schema version on `nightly` for any additive migration (§10).
5. Filter chip set finalization (do Bookmarks/Cards/Notes each get a chip, or live under a "Marks" group?).

---

## 14. Out of scope
watchOS, Widget, CarPlay surfaces; alignment/narration engine changes; now-playing screen redesign; new SRS scheduling logic.
