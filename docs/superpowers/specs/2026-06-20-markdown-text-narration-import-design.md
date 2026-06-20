# Markdown / Plain-Text Narration Import — Design

- **Date:** 2026-06-20
- **Status:** Approved (brainstorm) → ready for implementation plan
- **Author:** Dan Fakkeldy (with Claude)
- **Branch:** `claude/pensive-lumiere-47f48c`

## Goal

Let users import Markdown (`.md`, `.markdown`) and plain-text (`.txt`) files as
narratable, audio-less books — feeding the same on-device Kokoro (ONNX) narration,
read-along timeline, and chaptered playback the app already produces from EPUBs.

The request: "import markdown/plain text files for narration as well." The target
flow is the **standalone narrate path** — a picked text file becomes a new
audio-less book the user can narrate, exactly like a lone study EPUB today.

## Why this is small

Everything downstream of parsing is already format-blind. `parseEPUBBlocks`
([Shared/EPUBBlockParser.swift:49](../../../Shared/EPUBBlockParser.swift)) turns an
EPUB into `[EPubBlockRecord]`; chapter planning
([NarrationChapterPlanner](../../../EchoCore/Services/Narration/NarrationChapterPlanner.swift)),
text normalization, chunking, the Kokoro ONNX engine, alignment anchors, and the
read-along timeline all consume those block rows and never inspect the source
format. So the feature reduces to **one new parser that emits the same block set**,
reusing the existing persist + narrate path. No schema change.

## Decisions (from brainstorming)

1. **Plain-text chapters:** heuristic "Chapter N" detection (scan for chapter-like
   lines), with a **single-chapter fallback** when none are found. Markdown uses its
   real headings.
2. **Markdown fidelity:** smart-strip to clean prose for narration **plus** capture
   bold/italic (and strikethrough) spans into the existing `textFormats` field so the
   read-along reader renders emphasis. Code fences, tables, and images are skipped
   for narration.
3. **Title & headings:** **filename is the book title**; author left blank. **Every
   heading of any level (`#`…`######`) starts a new chapter.** (Accepted nuance:
   deeply nested `###` subheadings each spawn their own chapter — a heavily
   subdivided file fragments into many chapters. Acceptable for v1; revisit only if it
   bites.)
4. **Platforms:** iOS **and** macOS together. Core logic lives in `Shared/` /
   `EchoCore/` (one copy); only the two platform pickers differ.

## Architecture — Approach A (share the post-parse import path)

`EPUBImportService.import`
([EchoCore/Services/EPUBImportService.swift:36](../../../EchoCore/Services/EPUBImportService.swift))
is two phases glued together:

1. `parseEPUBBlocks(...)` → the block set (EPUB-specific).
2. Persist / post-process: image copy, TOC resolution, chapter-index assignment,
   DB write (largely format-agnostic).

**Split phase 2** into `import(parse:audiobookID:chapters:bookDuration:)` and let the
new text parser feed it the same `EPUBBlockParse` value. The EPUB-only steps
**self-skip** for text:

- The image-copy loop guards on `blockKind == .image` — Markdown emits none.
- `resolveTOCEntries` returns `[]` for an empty TOC tree
  ([EchoCore/Services/EPUBImportService.swift:190](../../../EchoCore/Services/EPUBImportService.swift)).

Net: one extracted method, **zero duplicated chapter/persist/timeline logic**, no
schema change.

**Each chapter is modelled as one synthetic spine item** (`spineIndex`). This makes
the existing standalone-book branch
([EPUBImportService.swift:142–163](../../../EchoCore/Services/EPUBImportService.swift))
map body spines → 0-based chapter indices unchanged, and auto-excludes front matter
(anything before the first heading) from narration — the same way an EPUB
cover/copyright page is excluded. "Every heading = a chapter" becomes "every heading
starts a new spine."

**Rejected alternatives:**

- **B — Parallel `TextImportService`:** re-implements chapter-index assignment,
  persistence, and timeline recalc. Invites EPUB/text divergence — the exact failure
  mode the `parseEPUBBlocks` unification (CODE_AUDIT §5.1) was built to prevent.
- **C — Synthesize a throwaway EPUB from Markdown:** trades a clean parser for a
  Markdown→XHTML/OPF/NCX generator (its own fidelity surface) and writes junk
  scaffolding to disk.

## The parser — `Shared/TextDocumentParser.swift`

Two entry points, both returning the existing `EPUBBlockParse` (drop-in for
Approach A):

```swift
func parseMarkdownBlocks(audiobookID: String, fileURL: URL) throws -> EPUBBlockParse
func parsePlainTextBlocks(audiobookID: String, fileURL: URL) throws -> EPUBBlockParse
```

### Markdown block mapping

| Markdown element | Becomes | Narrated? |
|---|---|---|
| `#`…`######` heading | new spine (`spineIndex++`) + `heading` block; heading text = chapter title | yes |
| Paragraph (blank-line delimited) | `paragraph` block | yes |
| List item (`-`/`*`/`+`/`1.`) | one `paragraph` block per item, marker stripped | yes (reads as a sentence) |
| Blockquote (`>`) | `paragraph` block, `>` stripped | yes |
| Fenced/indented code, tables, images | **dropped from the stream** | no |
| `**bold**` / `*italic*` / `~~strike~~` | plain text + `TextFormat(type:range:)` span | text only |
| `[label](url)` link | `label` only (URL dropped) | yes |

### Plain-text (`.txt`)

- Same blank-line paragraph splitting.
- Chapters from the heuristic: a line matching
  `^\s*(chapter|part|book)\s+(\d+|[ivxlcdm]+)\b…` (case-insensitive), a bare numbered
  line, or a short ALL-CAPS line, starts a new spine with that line as the heading.
- **No markers found → exactly one spine / one chapter.**

### Shared rules

- **Front matter:** prose before the first heading → `isFrontMatter = true` (shown in
  reader, excluded from narration). Title always from the filename; author blank.
- **Block IDs:** reuse `epub-<audiobookID>-s<spine>-b<block>`, assigned in reading
  order — reproducible, so re-importing the same file yields identical IDs (alignment
  anchors depend on this).
- **Word count:** split-based per block, matching the EPUB importer.
- **`TextNormalizer`, pronunciation overrides, and the chunker are unchanged** — they
  operate on block text after import.

### Inline formatting extraction (Foundation-only, no new dependency)

Hand-roll only the *block* structure (line-based: headings, blank-line paragraphs,
code fences). For each prose block, run `AttributedString(markdown:)` in inline-only
mode and walk its `inlinePresentationIntent` runs — `.stronglyEmphasized → .bold`,
`.emphasized → .italic`, `.strikethrough` — converting each run's range into the
existing `TextFormat(type:range:)`
([Shared/EnhancedTranscriptionSegment.swift:43](../../../Shared/EnhancedTranscriptionSegment.swift)).
Foundation yields correct emphasis spans (including nested `***both***`) without
pulling in `swift-markdown`. This mirrors the repo's ethos of parsing EPUB with
`XMLParser` rather than a library. If full CommonMark edge-case fidelity is ever
needed, swapping in `apple/swift-markdown` is a localized change behind this function.

## Wiring

### Shared core (compiled into both targets)

- **New** `Shared/TextDocumentParser.swift` — the parser above.
- **Refactor** `EPUBImportService` — extract
  `import(parse:audiobookID:chapters:bookDuration:)`; existing `import(epubURL:…)`
  becomes a thin wrapper that calls `parseEPUBBlocks` then the new method.
- **New** `TextAutoImportScanner.importTextFile(…)` — the text counterpart to
  `EPUBAutoImportScanner.importEPUBFile`
  ([EchoCore/Services/EPUBAutoImportScanner.swift:87](../../../EchoCore/Services/EPUBAutoImportScanner.swift)):
  read file → parse → `import(parse:)` → **shared finalize tail** (initial system
  anchors first→0 / last→duration, CloudKit sidecar check, timeline recalc). Extract
  that tail from `importEPUBFile` into a shared helper so both scanners call one copy.

### iOS

| File | Change |
|---|---|
| [PlaylistManager.swift:38](../../../EchoCore/Services/PlaylistManager.swift) | `documentExtensions` += `"md"`, `"markdown"`, `"txt"`, `"text"` — makes a picked text file open audio-less via `isDocumentFile`. |
| [FolderPicker.swift:12](../../../EchoCore/Utilities/FolderPicker.swift) | Add `.plainText` + `UTType(filenameExtension: "md")` / `"markdown"` so the picker shows text files. |
| [PlayerLoadingCoordinator.swift:201](../../../EchoCore/Services/PlayerLoadingCoordinator.swift) | `importDocumentForAudiolessBook`: add a text branch alongside `importedEPUBFile` → `TextAutoImportScanner.importTextFile`. |

### macOS

| File | Change |
|---|---|
| [Echo_macOSApp.swift:278](../../../Echo%20macOS/Echo_macOSApp.swift) | EPUB `NSOpenPanel`: add md/markdown/txt content types; route text files the way `.epub` files are enqueued. |
| [MacBatchProcessingService.swift:251](../../../Echo%20macOS/Services/MacBatchProcessingService.swift) | `importEPUBOnly` path: branch to the text parser for `.md`/`.txt`, then the shared `import(parse:)`. |
| Xcode target membership | Both new files must be added to **both** the iOS and macOS targets (the codebase has had iOS-only files silently miss macOS — e.g. the `PlayerModel+Audiobookshelf` exclusion). |

Cover art needs no work — a standalone text book gets the same default cover
treatment as a standalone EPUB.

## Testing (TDD)

- **`TextDocumentParserTests`** (bulk):
  - *Structure:* N headings → N spines/chapters; blank-line paragraph splitting; list
    items → one block each; blockquote `>` stripped; fenced code / tables / images
    dropped (asserted absent); link → label-only.
  - *Inline formatting:* `**bold**`, `*italic*`, `~~strike~~`, nested `***both***`
    produce `TextFormat` spans at correct character offsets of the stripped text.
  - *Front matter:* prose before the first heading is `isFrontMatter == true`; title
    from filename.
  - *Plain text:* `Chapter 7` / `CHAPTER VII` / bare-number / short ALL-CAPS lines
    split chapters; no markers → exactly one spine/chapter.
  - *ID stability:* same input → identical `epub-…-s…-b…` IDs across two parses.
- **`TextImportIntegrationTests`** using `DatabaseService(inMemory:)`: parse a small
  Markdown fixture → `import(parse:)` → assert `epub_block` rows persisted, each
  chapter's blocks carry the right `chapterIndex`, front-matter blocks stay `nil`.
- **Refactor safety:** existing `EPUBImportService` / `EPUBAutoImportScanner` tests
  must stay green — proves extracting `import(parse:)` and the shared finalize tail
  did not change EPUB behavior.

Workflow: `make build-tests` once, then
`make test-only FILTER=EchoTests/TextDocumentParserTests` (and the integration
suite). Cross-platform parity: confirm both new files build into the macOS target.

## No schema migration

Blocks land in the existing `epub_block` table. Current migration head is **V23** and
stays V23. No `schema-migration-reviewer` pass required.

## Out of scope (v1)

- **Attaching a `.md`/`.txt` to an existing *audio* book** for read-along (the
  `model.importEPUB` / `EPUBImportCoordinator` path, whose copy-loop only preserves
  `.pdf`/`.epub`). The request is narration of text, which is the standalone path.
  Clean follow-up.
- **Render-but-don't-speak** code blocks (no such block kind today; code is dropped).
- **Image resolution** for `![](…)` references.
- **Multi-file books** (a folder of `.md` chapters).

## Docs to sync (before PR, via `doc-sync` skill)

- `README.md` — supported import formats now include Markdown / plain text.
- `ARCHITECTURE.md` — the text parser + the generalized document-import seam.
- `CHANGELOG.md`, `ROADMAP.md`.
