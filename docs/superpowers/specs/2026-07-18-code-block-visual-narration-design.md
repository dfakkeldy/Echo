# Code Blocks as Visual Narration Blocks — Design

**Date:** 2026-07-18
**Status:** Approved (brainstorm complete; implementation plan pending)
**Scope:** EPUB + Markdown import, narration pipeline, reader feed, Visual Listening slideshow

## Problem

Coding textbooks narrate badly today, in two opposite ways:

- **EPUB:** `<pre>`/`<code>` are unknown to `XHTMLBlockDelegate` (`Shared/EPUBXMLParsing.swift:492-498`), so listing text is flattened into the surrounding prose block — with indentation and newlines destroyed by `appendCollapsed` (`Shared/EPUBXMLParsing.swift:671-686`) — and read aloud by Kokoro as word soup.
- **Markdown:** the tokenizer detects ``` fences and **discards** every fenced line (`Shared/TextDocumentParser.swift:73-82`). Code is silent but also invisible.

Meanwhile the app already has a "displayed but not spoken" primitive: `.image` blocks (`text == nil`, `imagePath` set) are skipped by narration (text-presence filter, `EchoCore/Services/Narration/NarrationRenderPlan.swift:99-103`) yet render in the reader feed (`ImageCardCell`) and surface in the Visual Listening slideshow anchored to the audio timeline (`Shared/VisualListeningCueResolver.swift`). This design extends that model to code.

## Requirements (from brainstorm)

1. **Audio at a code block:** a short spoken cue — the listing's caption when detectable, else "Code listing." — then narration continues with prose. Never read code syntax aloud; never pure silence.
2. **Display:** native text rendering — monospaced, dark-mode/Dynamic Type aware, selectable for copy-out. Syntax highlighting valued but phased. A rasterized PNG does not meet the bar as the end state.
3. **Formats:** EPUB and Markdown in this change. PDF code detection explicitly out (no semantic markup; heuristic-heavy sub-project).
4. **Tables:** out of scope; focused follow-up change. They keep today's flattened-and-spoken behavior for now.

## Approach decision

**Chosen: native `.code` block kind, phased polish** (over (B) rasterize-to-PNG reusing `.image`, and (C) native + cached PNG).

Rationale: block kinds are written at import time, so data-model regret costs every user a re-import. Native text is the only representation satisfying the display requirements; surfaces that later need an image (deck cards) can rasterize the same cell on demand with `ImageRenderer`. PNG-first would be a dead end requiring a second re-import; native+PNG duplicates storage to solve a deck problem we have not hit.

## Design

### 1. Data model

- **New kind:** `EPubBlockRecord.Kind.code`, raw value `"code"`. No schema migration for the kind itself — `block_kind` is plain `TEXT NOT NULL` (`Shared/Database/Migrations/Schema_V1.swift:240`), and unknown kinds fail soft: `Kind(rawValue:)` returns `nil` and callers degrade to default behavior, so older readers of a newer DB do not crash.
- **New column:** `code_language` (nullable TEXT) on `epub_block` via a new schema migration (version number assigned at implementation time from the current max on `origin/nightly` — Echo has had cross-branch version collisions before). Populated from `class="language-…"`-style attributes (EPUB) or the fence info string (Markdown). Captured now, even though highlighting is phase 2, because a missed import-time column means another re-import later. Run the `schema-migration-reviewer` agent on the migration before commit (version-collision + test checks).
- **Block content:** `text` = raw code with whitespace/newlines preserved (the display copy). `narrationText` = the spoken cue, set at import.
- **Compiler-forced updates** (exhaustive switches over `Kind`): reader a11y labels (`EchoCore/Views/ReaderFeedCollectionView.swift:551-562`), `EchoCore/Services/BlockExportDocument.swift:77-83` (counts), `Shared/Services/StudyDeckSourceBuilder.swift:83-88` (`isTextBlock` — code classified with `.image`, i.e. not prose).
- **Equality-site review** (compile but would misclassify): `AlignmentService.swift:198`, `EstimatedAlignmentSidecar.swift:78`, `NarrationChapterPlanner.swift:66`, `TimelineItem.swift:114`, `ReaderTab+Alignment.swift:186,313`, Visual Listening `== .image` filters. Each gets an explicit decision in the plan (see §3 and §5 for the load-bearing ones).

### 2. Parsing

**EPUB (`XHTMLBlockDelegate`):**

- New `isInPreformatted` state. On `<pre>` start: flush the open block, begin raw character capture — `foundCharacters` bypasses `appendCollapsed`, and `insertSoftWordBreakIfStructural` is suppressed while the flag is set (verified: every current path collapses; the bypass is new state, not a tweak).
- On `</pre>`: emit a `.code` block. Empty/whitespace-only listings are dropped.
- Nested markup inside `<pre>` (publisher syntax-highlight `<span>`s, nested `<code>`) contributes characters only.
- Language sniff: `class` attribute on `<pre>` or its immediate child `<code>` (`language-*`, `lang-*`, `brush:` variants).
- **Cue:** if the `<pre>` sits inside a `<figure>` with a `<figcaption>`, the figcaption text becomes `narrationText` (figcaption is otherwise in `skipTags`; it is captured only in this configuration). Else `narrationText = "Code listing."`. No further caption heuristics in v1.
- **Inline `<code>` outside `<pre>` is untouched** — stays part of the sentence and is spoken ("call `len()` on the list" reads normally).

**Markdown (`TextDocumentParser`):**

- New `TextUnit.code(text:language:)` case. Fenced lines accumulate instead of `continue`-ing (`TextDocumentParser.swift:82`); fence info string supplies the language; `buildParse` maps the unit to a `.code` block with the generic cue.
- Plain-`.txt` import: unchanged (no fence syntax to detect).

### 3. Audio, QA, timing

- **Speaking the cue:** synthesis does NOT read the `narrationText` column — `prepareBlocksForRenderPlan` recomputes FM-normalized text from `block.text` (`EchoCore/Services/Narration/NarrationService.swift:843-865`). The one pipeline change: `.code` blocks skip `TextNormalizer`/FM entirely and set the prepared block's spoken text to `narrationText ?? "Code listing."`. (Import always sets `narrationText` for `.code` blocks; the `??` fallback is defensive only, so audio and QA can never diverge.) Downstream (chunker, synthesis, timeline) is unchanged — the chunker never sees raw code.
- **QA free ride:** `NarrationQAService` already scores ASR against `narrationText ?? text` (`NarrationQAService.swift:88`), so re-QA validates the cue, never diffs against code. Implementation verifies the divergence classifier doesn't penalize very short blocks.
- **Word timing — deliberately block-level:** the spoken-path materializer tokenizes the spoken text with sparse indices (`WordTimingMaterializer.materializeSynthesizedChapter`), while cells index display-text tokens; a 2-word cue vs a 40-token listing would highlight almost nothing (silent no-op guard, `ParagraphCardCell.swift:267-279`). Rather than build index remapping, `CodeCardCell` does no word-level highlighting — block-level active state (`isActiveBlock`) only. Word-karaoke over code the narrator isn't reading would be misleading anyway. Cue word rows that get written are harmless and ignored.
- **Timeline:** the code block gets a normal `timeline_item` spanning the cue utterance — this anchors reader auto-scroll and the Visual Listening display window. Implementation checks `NarrationChapterPlanner.swift:66`'s image special-case does not skip code blocks (they have text; default path should include them).
- **Auto-alignment (commercial audiobook + EPUB DTW): exclude `.code` like `.image`.** Human narrators skip or paraphrase code; code tokens would poison DTW matching. Both image-exclusion sites (`AlignmentService.swift:198`, `EstimatedAlignmentSidecar.swift:78`) add `.code`.

### 4. Reader feed rendering

- New `CodeCardCell`, registered alongside existing cells, with a `case Kind.code.rawValue` branch in the dispatch switch (`ReaderFeedCollectionView.swift:458` — raw-string switch with `default`; without the branch, code silently renders as a paragraph card).
- Cell behavior: monospaced Dynamic Type font, theme-aware secondary background, **horizontal scroll for long lines (never wrap code)**, selectable text (non-editable text view) for copy-out, block-level active highlight, accessibility label "Code listing" with the code as value.

### 5. Visual Listening slideshow

The one real model change: `VisualListeningImageCue` requires `imagePath` and `hasContent` gates on image blocks (`VisualListeningViewModel` `:138-154`), so `.code` cannot ride through as-is.

- Cue payload generalizes to an enum: `.image(path:)` / `.code(text:language:)`.
- Resolver selection predicate (`VisualListeningCueResolver.swift:143-147`) adds `.code` blocks (no `imagePath` requirement for that arm).
- `hasContent` becomes *has-any-visual* (image or code) && has-subtitle.
- `VisualListeningStageView` renders the code payload as a scrollable monospaced view with the caption overlay; the Begin/Middle sync-point picker and derived-window timing logic are payload-agnostic and unchanged.
- `MacVisualStageView` gets the same treatment. Run `cross-platform-parity-reviewer` before the PR (macOS/watch/widget surfaces).

### 6. Study surfaces

- `StudyDeckSourceBuilder` treats `.code` as non-prose (grouped with `.image`) so deck text generation does not ingest raw code.
- Deck cards displaying a referenced listing (`imageAnchor` → resolve block → `ImageRenderer` rasterization on demand) is **deferred**.

## Out of scope (deferred)

- Syntax highlighting (phase 2 layer on `CodeCardCell`; a third-party highlighter requires separate approval per project dependency rules).
- Tables (same defect class; focused follow-up — the parser pattern built here makes it mechanical).
- PDF code detection.
- Deck-card code images; word-tap-to-seek inside code blocks.
- Rewriting already-imported books: existing flattened blocks persist until the user re-imports. Known behavior, not a bug.

## Testing

- **Parser (core):** indentation/blank-line preservation through `<pre>`; nested `<span>`/`<code>` inside `<pre>`; `<figure>`+`<figcaption>` cue capture; inline `<code>` remains spoken prose; empty `<pre>` dropped; language-class sniffing; Markdown fence emission incl. language and unterminated-fence handling; tables unaffected.
- **Pipeline:** prepared `.code` block speaks exactly the cue; QA expected text resolves to the cue; `VisualListeningCueResolver` emits code cues with derived windows; alignment token streams exclude `.code`; `NarrationChapterPlanner` includes code blocks.
- **Harness:** `make test`; where the iOS-26 sim runner is flaky for pure-logic code, the standalone `swiftc` harness pattern (compile real sources into a `main.swift` harness) applies.
- **End-to-end:** import a real Python textbook EPUB, narrate a chapter via `echo-cli narrate` (built with `make echo-cli` only), verify audio (cue then prose), reader feed (code card, block highlight), and Visual Listening (listing surfaces during adjacent prose).

## Documentation impact

Block data model and narration pipeline change: update `ARCHITECTURE.md` (block kinds, parser behavior, Visual Listening cue model) and `CHANGELOG.md`. Include a doc-sync step in the implementation plan.

## Risks / open items

- Cue caption coverage will be low in v1 (figcaption-in-figure only); most listings will say "Code listing." Acceptable; richer caption detection is a follow-up.
- Publishers with exotic code markup (e.g. `<div class="code">` without `<pre>`) won't be detected in v1; blocks fall back to today's flattened-spoken behavior for those books.
- The divergence classifier's behavior on 2-word blocks needs verification during implementation (flagged in §3).
