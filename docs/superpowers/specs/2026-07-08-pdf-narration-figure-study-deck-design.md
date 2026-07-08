# On-Device PDF Narration + Aligned Read-Along + Figure-Rich Study Deck — Design

- **Status:** Approved design (implementation plan: _to be written next_)
- **Date:** 2026-07-08
- **Author:** Dan Fakkeldy (with Claude)
- **Branch base:** `nightly` (`claude/ios-pdf-narration-study-deck-fae1f8`, history includes `origin/nightly` @ `a66bf39d`)
- **Origin:** Owner request — "use an iOS simulator to narrate `Day 1 v3.pdf`, make sure it stays aligned, fix anything along the way, and make a really good study deck with lots of memorable pics." Deliver the finished book package to `~/Library/Mobile Documents/com~apple~CloudDocs/Books/Books to test echo`. Pictures: real PDF diagrams where a concept has one, Codex-generated memorable images (via the owner's Codex pic-maker) for the rest.

## Context

The source is not an unknown-author file — it is a polished **51-page whitepaper, "The New SDLC With Vibe Coding — From ad-hoc prompting to Agentic Engineering"** (Addy Osmani, Shubham Saboo, Sokratis Kartakis; Adobe InDesign, May 2026), letter size, with a real table of contents. `pdfimages` reports **~16 embedded 300-DPI figures** (each a JPEG-2000 `jpx` image plus a soft-mask). It is concept-heavy prose (low on the decimal/number patterns that most stress alignment).

This request touches three capabilities that are at very different maturity levels in Echo today:

1. **Narrating a PDF on-device** — already possible. `HeadlessNarrationRunner` accepts a `.pdf` directly and renders with the real on-device ONNX/Kokoro engine.
2. **Keeping generated narration aligned** — mostly already correct *by construction* (word timing comes from Kokoro's duration head at synthesis, not ASR), but has known guard bugs documented in `NARRATION_AUDIT.md` that silently drop many blocks to low-confidence interpolation.
3. **"A really good study deck with lots of memorable pics"** — **not supported today**. PDF import is text-only (never extracts figures), all AI/import deck paths are text-only, and the general review card renders no image. This is the bulk of the new work.

### What already exists and is reused, not reinvented

- **Headless narration** — [`HeadlessNarrationRunner`](../../../EchoCore/Services/Narration/HeadlessNarrationRunner.swift) (`run(_:tts:progress:)`), which accepts an expanded EPUB dir / `.epub` / **`.pdf`** (`resolveNarrationSource`), imports blocks, renders per-chapter ALAC + `.anchors-ch<N>.json` resume markers, and exports a chaptered `.m4b` + portable `.alignment.json` sidecar. Default engine is [`OnnxKokoroEngine`](../../../EchoCore/Services/Narration/OnnxKokoroEngine.swift) via [`NarrationEngineFactory`](../../../EchoCore/Services/Narration/NarrationEngineFactory.swift).
- **PDF import → blocks** — [`PDFAutoImportScanner`](../../../EchoCore/Services/PDFAutoImportScanner.swift) (`importPDFFileOutcome`, PDFKit text extraction on a detached task, synthetic page-chapters for marker-less PDFs) → [`EPUBImportService.import(parse:)`](../../../EchoCore/Services/EPUBImportService.swift) → [`DocumentImportFinalizer`](../../../EchoCore/Services/DocumentImportFinalizer.swift) → [`PDFBlockPageMapper`](../../../EchoCore/Services/PDFBlockPageMapper.swift)/`pdf_block_page`.
- **Image blocks** — [`EPubBlockRecord`](../../../Shared/Database/EPubBlockRecord.swift) already has `image_path` (`:22`) and a `block_kind = image` constant (`:92`); EPUB imports already create image blocks. PDF import will mirror this exactly.
- **Synthesis word timing** — [`KokoroWordTimer`](../../../EchoCore/Services/Narration/KokoroWordTimer.swift), [`NarrationWordTimingAssembler`](../../../EchoCore/Services/Narration/NarrationWordTimingAssembler.swift), and [`WordTimingMaterializer`](../../../Shared/Services/WordTimingMaterializer.swift) (`materializeSynthesizedChapter`, `refineWithSynthesis`) write `word_timing` rows at `synthesis`/`synthesized`/`interpolated` confidence.
- **PDF read-along** — [`PDFReadAlongController`](../../../EchoCore/Views/PDFReadAlongController.swift) + [`ReaderActiveBlockResolver`](../../../Shared/ReaderActiveBlockResolver.swift) + [`PDFDocumentView`](../../../EchoCore/Views/PDFDocumentView.swift) (page auto-follow + PDFKit word search).
- **Deck import (vNext)** — [`FlashcardDeckImport`](../../../EchoCore/Models/FlashcardDeckImport.swift) format + [`DeckImportService.importDeckVNext`](../../../EchoCore/Services/DeckImportService.swift) + [`EPUBSourceAnchorResolver`](../../../EchoCore/Services/EPUBSourceAnchorResolver.swift) (portable `s<i>-b<j>` anchor → device-local block id). Existing exporter/format: `echo-cli deck` → `StudyDeckFileExporter.writeImportDeck` via [`GenerateDeckCommand`](../../../Tools/echo-cli/GenerateDeckCommand.swift) (reused as the deck-JSON shape; the deterministic `FixtureStudyDeckGenerator` content is **not** reused — cards are hand-authored for quality).
- **Card image machinery** — [`StudyCardMedia`](../../../Shared/Study/StudyPlanTypes.swift) (`imagePath`), [`StudyLocalImageView`](../../../EchoCore/Views/StudyAssignmentCardView.swift) (`UIImage/NSImage(contentsOfFile:)`), `flashcard.media_json` column (already exists). The `.apkg` importer's media-copy step ([`ApkgImportService.importMediaFiles`](../../../EchoCore/Services/ApkgImportService.swift)) is the precedent for copying bundled image bytes into Echo-owned storage.
- **Card render router** — [`StudySessionView`](../../../EchoCore/Views/StudySessionView.swift) (`StudySessionCardView`) routes only `imageAssignment`/`listening`/`vocabulary` to the image-capable `StudyAssignmentCardView`; normal Q&A/cloze go to [`FlashcardReviewCard`](../../../EchoCore/Views/FlashcardReviewCard.swift) (iOS) / `StudyInlineReviewCard` (macOS), which render **text only** — the render gap this design closes.

## Goals

1. Produce a narrated, chapter-structured `.m4b` of the whitepaper rendered by the real on-device engine on the **iOS simulator**, with block + word timing that drives accurate in-app read-along highlighting.
2. Diagnose and, where this book needs it, **fix** the synthesis-timing guard bugs so read-along stays tight through abbreviation/number-heavy blocks.
3. Add a **durable, reusable** in-app capability to extract a PDF's embedded figures during import and represent them as first-class image blocks.
4. Extend the deck-import format into a small **bundle** that can attach either an in-book figure (by anchor) or a bundled generated image (by file) to any card, and render that image on the general review card.
5. Hand-author a strong study deck for the whitepaper; attach real diagrams where they fit and Codex-generated memorable images elsewhere so **every card is visual**.
6. Verify the whole thing end-to-end **on the simulator** (read-along tracks audio; figure/mnemonic cards render), and deliver the complete package to the iCloud folder.

## Non-Goals

- **No schema migration.** Every piece reuses existing columns/tables (`epub_block.image_path`, `pdf_block_page`, `flashcard.media_json`). `main` is already at V35; adding a migration is the single most collision-prone risk and is explicitly avoided.
- **No change to the ASR/DTW import-alignment path** (`AutoAlignmentService`, `SourceBackedAlignmentCoordinator`) — generated narration does not use it.
- **No emoji/SF-Symbol mnemonic system** — superseded by the Codex pic-maker.
- **No on-device image generation in Echo** — raster synthesis stays in Codex (`imagegen`), consistent with Echo's on-device/GPL posture. Echo only *renders* image files it is handed.
- **Not** a general "narrate any PDF from the app UI" flow — the render is driven headlessly for this task (the durable parts are figure extraction, deck-image bundles, and card rendering).

## Architecture Overview

Five parts, each independently buildable and testable:

```
A. Sim narration harness ──▶ B. Alignment repair (evidence-driven)
        │
        ▼  (PDF import, during A)
C. PDFFigureExtractor ──▶ epub_block image blocks (image_path, s<i>-b<j>)
        │
        ▼
D. Deck bundle format + import (imageAnchor | imageFile) ──▶ mediaJSON.imagePath ──▶ E5. card render
        │
        ▼
E. Authored deck + Codex mnemonic pics ──▶ import ──▶ on-sim verification ──▶ iCloud delivery
```

## Component Designs

### 5.1 Sim narration harness (real engine)

A **gated** Swift-Testing case (mirroring [`OnnxKokoroEngineWordTimingTests`](../../../EchoTests/OnnxKokoroEngineWordTimingTests.swift), `.enabled(if:)` on an env var, e.g. `ECHO_NARRATE_PDF_IT=1`) constructs a `NarrationRunConfig` with `epubURL` = the PDF, a **persistent** `databaseURL` (so blocks, anchors, and `word_timing` survive across batches for later deck-linking + inspection), a `workDir`, `sidecarURL`, `voice = af_heart`, and `maxNewChaptersPerRun = 5`. It calls `HeadlessNarrationRunner().run(cfg)` **without a stub** so `NarrationEngineFactory.make()` yields the real `OnnxKokoroEngine` (first run downloads the pinned 163 MB `model_fp16.onnx` into the sim's Application Support).

- Run under the `Echo` scheme on `platform=iOS Simulator,name=iPhone 17` with `CODE_SIGNING_ALLOWED=NO` (Makefile `SIM_DEST`/`CODESIGN_OFF`). Invoked via `make test-only FILTER=EchoTests/<SuiteName>` with the env var set.
- **Batching/resume:** the runner renders `pending.prefix(5)`, writes `.anchors-ch<N>.json`, and returns `complete:false` until all chapters are captured; the harness is re-invoked (loop) until it exports the `.m4b` + sidecar. `.anchors-ch<N>.json` is the in-repo resume flag (there is no in-repo `.done`/job-JSON mechanism).
- **Fallback (documented, not default):** if the sim proves too slow or OOMs, the native macOS `echo-cli narrate --epub <pdf> --out … --sidecar … --db … --max-chapters 5` path renders the identical artifacts off-sim; the resulting audio + sidecar can be imported into the sim app for study. The owner asked for the simulator, so the sim harness is the primary path.

**This test is committed** (gated off by default, so CI stays green) — it is the durable "narrate a real PDF on the sim with the real engine" coverage that the repo currently lacks.

### 5.2 Alignment repair (evidence-driven, `systematic-debugging` + TDD)

After batch 1, read the `"Synthesis word timing: X/Y blocks overrode interpolation"` log ([`NarrationService`](../../../EchoCore/Services/Narration/NarrationService.swift) ~`:506`) and inspect the `.alignment.json` sidecar + `word_timing.source/confidence` distribution. If a large fraction of blocks fell back to `interpolated` (0.5) instead of `synthesis` (0.9), apply the fix `NARRATION_AUDIT.md` §5.16 recommends:

- Replace the brittle count-equality gates — `KokoroWordTimer` requiring `groups.count == wordCount` ([`KokoroWordTimer.swift:56`](../../../EchoCore/Services/Narration/KokoroWordTimer.swift)) and `WordTimingMaterializer.refineWithSynthesis` requiring `rows.count == timings.count` ([`WordTimingMaterializer.swift`](../../../Shared/Services/WordTimingMaterializer.swift) ~`:228`) — with a **source-token → spoken-word index map**, so numbers/abbreviations that Misaki expands into multiple phoneme groups still carry their exact duration-head timing.
- Also confirm the §5.17 silence-split rescale and §5.1 decimal-split chunker do not corrupt this book's text; fix only if observed here.

Each fix is written test-first against a focused fixture (a block containing "80%", "CapEx/OpEx", an em-dash) proving the timing survives at `synthesis` confidence. **Scope guard:** fix only what this book's evidence demands; do not attempt an open-ended timing rewrite.

### 5.3 `PDFFigureExtractor` + image blocks (durable)

New service `PDFFigureExtractor` (approach: **rect-rasterization**, chosen because this PDF's figures are JPEG-2000 + soft-mask, which the raw-XObject path handles poorly):

1. Open the PDF with CoreGraphics `CGPDFDocument`. For each page, scan the content stream (`CGPDFScanner` / `CGPDFOperatorTable`) to find image-draw operators and their current transform matrix → the on-page rectangle of each placed image.
2. Filter out tiny/decorative images (area/size threshold) so only real figures survive.
3. Rasterize each surviving rect from the rendered page to a PNG at a sensible DPI, write to Echo-owned per-book asset storage (mirroring where EPUB image blocks store bytes — exact directory pinned in the plan).
4. Return `[(pageIndex, imagePath, orderOnPage)]`.

Wire into `PDFAutoImportScanner.importPDFFileOutcome`: after text blocks are parsed, **interleave `block_kind = image` blocks at their page position** (so `s<i>-b<j>` anchoring and `pdf_block_page` stay coherent), with `image_path` set and `text` empty. Image blocks must be:
- **excluded from narration** (Kokoro renders text blocks only — verify image blocks are skipped, matching EPUB image-block behavior), and
- **not counted** toward the read-along word/karaoke stream.

Behind a small feature flag / guard so a PDF with no detectable figures imports exactly as today (regression-safe).

### 5.4 Deck bundle format + import (two attach modes)

The deck becomes a **folder bundle**: `<name>.echo-deck.json` + an `images/` subfolder. Extend [`FlashcardDeckImport.ImportedCard`](../../../EchoCore/Models/FlashcardDeckImport.swift) with two optional, mutually-exclusive fields:

- `imageAnchor: String?` — a portable `s<i>-b<j>` pointing at an extracted figure block. `DeckImportService.importDeckVNext` resolves it via `EPUBSourceAnchorResolver` to the block's `image_path` and writes `mediaJSON` (`StudyCardMedia { imagePath }`). Zero image bytes in the JSON; the figure lives in the book's blocks.
- `imageFile: String?` — a path relative to the bundle's `images/` folder (a Codex-generated PNG). The importer **copies** the file into Echo-owned storage (reusing the `.apkg` media-copy precedent) and writes `mediaJSON.imagePath` to the durable copy.

Both terminate at `flashcard.media_json`. Validation: reject a card that sets both; tolerate a missing/failed image (card imports as text-only, logged). Backward-compatible: decks without these fields import unchanged.

### 5.5 Card image rendering (the one net-new view change)

Make `FlashcardReviewCard` (iOS) and `StudyInlineReviewCard` (macOS) render `StudyCardMedia.imagePath` (decoded from `mediaJSON`) **above** the Q&A text when present, reusing the existing `StudyLocalImageView` load path (`contentsOfFile`, placeholder on missing file). No routing change needed — any card can now carry an image regardless of `cardType`.

### 5.6 Deck authoring + Codex mnemonic-pic manifest

Claude hand-authors the deck from the whitepaper's real concepts (vibe coding vs. agentic engineering; context engineering; the harness/factory model; conductor vs. orchestrator; the 80% problem; CapEx/OpEx economics; intelligent model routing; where-to-start guidance), mixing `basic` and `cloze` cards, each `sourceAnchor`-linked to its source block for in-book deep-linking during playback.

Each card is tagged **needs-figure** (a real diagram exists on/near its source page → `imageAnchor` to that figure block) or **needs-mnemonic** (no diagram → entry in a `card→image-prompt manifest`). The Codex pic-maker turns each manifest prompt into a PNG in the bundle's `images/`, attached via `imageFile`.

**Codex execution (to confirm with owner):** primary attempt is to drive the Codex skill from this session via the codex bridge (`codex:rescue`); if the `image_gen` tool is not reachable through the bridge, Claude hands the owner the manifest to run in Codex and the owner drops the PNGs into `images/`. The app-side interface (`imageFile` → mediaJSON) is identical either way, so this choice does not affect the Swift design. _Open: the Codex skill's exact name/path (owner to confirm; likely the built-in `imagegen`)._

## Data Flow (end to end)

1. **Import + narrate (sim):** PDF → `PDFAutoImportScanner` (text blocks **+ figure image blocks** via 5.3) → `EPUBImportService.import(parse:)` → `DocumentImportFinalizer` → `pdf_block_page`. Then `HeadlessNarrationRunner`/`OnnxKokoroEngine` render text-block chapters → `word_timing` (`synthesis`/`synthesized`) + `.synthesized` anchors → `.m4b` + `.alignment.json`.
2. **Author + picture:** Claude authors cards (each `sourceAnchor`ed). needs-figure → `imageAnchor`; needs-mnemonic → manifest → Codex PNG → `imageFile`.
3. **Import deck bundle:** `DeckImportService.importDeckVNext` resolves each card's image (anchor → figure block's `image_path`, or bundled file → copied path) → `flashcard.media_json`.
4. **Study (sim):** `StudySessionView` shows cards; `FlashcardReviewCard`/`StudyInlineReviewCard` render the image (5.5). Playback read-along uses `PDFReadAlongController` over the `word_timing`/anchors from step 1.
5. **Deliver:** copy `.m4b`, `.alignment.json`, the deck bundle (json + `images/`), the extracted figure PNGs, the source PDF, and a README to `…/iCloud/Books/Books to test echo`.

## Deck Bundle Format (concrete)

```
Day-1-Vibe-Coding.echo-deck/
  deck.echo-deck.json
  images/
    card-03-context-engineering.png   # Codex mnemonic
    ...
```

```jsonc
{
  "deckName": "The New SDLC With Vibe Coding",
  "targetMediaID": "<book folder URL absoluteString>",   // portable via per-card sourceAnchor
  "cards": [
    {
      "frontText": "What distinguishes 'agentic engineering' from 'vibe coding'?",
      "backText":  "...",
      "triggerTiming": "manualOnly",
      "sourceAnchor": "s4-b12",
      "imageAnchor":  "s4-b3"          // an extracted PDF figure block
    },
    {
      "frontText": "What is 'context engineering' and why is it the real skill?",
      "backText":  "...",
      "sourceAnchor": "s3-b9",
      "imageFile":  "images/card-03-context-engineering.png"  // Codex mnemonic
    }
  ]
}
```

## Error Handling

- **Figure extraction failure** (unparseable content stream, no images): import proceeds text-only (`try?`-style, matching `pdf_block_page`'s best-effort capture); logged, never aborts import.
- **Narration OOM / partial:** runner returns `complete:false`; loop re-invokes with `--resume`/existing anchors. Crash partials (`.m4a` without a capture file) are swept and re-rendered.
- **Deck image resolution failure** (anchor points at a non-existent/non-image block, or bundled file missing): the card imports as text-only with a logged warning; import does not fail.
- **Both `imageAnchor` and `imageFile` set:** validation error on that card (skip its image, keep the card).
- **Alignment fix regressions:** guarded by new unit tests + the existing narration test suite; the fix is confidence-preserving, not behavior-changing for already-correct blocks.

## Testing Strategy (TDD)

- **Figure extraction:** unit tests over a small fixture PDF (embedded image at a known rect) → asserts an image block with a non-empty `image_path` at the right page, and that a figure-less PDF is unchanged.
- **Deck import:** tests that `imageAnchor` resolves to the figure block's path, that `imageFile` copies bytes into Echo storage and sets `mediaJSON`, that both-set is rejected, and that a legacy (no-image) deck still imports.
- **Card render:** view test / snapshot that a card with `mediaJSON.imagePath` renders an image and one without does not.
- **Alignment guards:** fixture blocks ("80%", "CapEx/OpEx", em-dash) prove `synthesis`-confidence timing survives after the fix.
- **Narration sim IT:** the gated real-engine test (5.1) — run manually, not in CI.
- All under `make build-tests` once, then `make test-only FILTER=EchoTests/<Suite>` (`CODE_SIGNING_ALLOWED=NO`). UI tests excluded per scheme.

## Verification (on-sim proof, before claiming done)

1. Open the narrated book in the sim reader; play; confirm read-along **highlighting tracks the audio** (block + word), including through an abbreviation/number block — alignment proof. Capture screenshots.
2. Open the deck; confirm a **needs-figure** card renders its real diagram and a **needs-mnemonic** card renders its Codex image. Screenshots.
3. Inspect `word_timing.source` distribution / the `"X/Y blocks overrode interpolation"` log to quantify alignment quality before/after the 5.2 fix.

## Delivery

- **One coherent PR into `nightly`**: `PDFFigureExtractor` + PDF-import wiring; deck-bundle format + `DeckImportService` two-mode image resolution; card render change; the alignment guard fix; the gated sim narration test.
- **Doc-sync:** update `ARCHITECTURE.md` (PDF figure extraction; deck-image bundle) and `CHANGELOG.md`; run the `doc-sync` skill before opening the PR. Remind owner if `README.md` needs a note.
- **Package to iCloud:** `.m4b`, `.alignment.json`, deck bundle (json + `images/`), figure PNGs, source PDF, README → `…/iCloud/Books/Books to test echo`. Large audio/scratch artifacts live under `~/Developer/echo-overnight` (off-git), consistent with existing overnight production.

## Risks & Mitigations

- **Real-engine narration is slow on the sim** (model download + jetsam batching). Chapter count is uncertain: `PDFAutoImportScanner` yields the whitepaper's TOC headings as chapters if `parsePlainText` detects them (~8), otherwise falls back to one synthetic chapter per page (`shouldUseSyntheticPageChapters`, up to ~51) — the latter means ~11 batched re-invocations. *Mitigation:* ≤5-ch batches + resume; documented `echo-cli` off-sim fallback producing identical artifacts. The actual chapter count is confirmed by inspection after batch 1, not assumed.
- **Content-stream image-rect detection is fiddly** across PDF producers. *Mitigation:* rect-rasterization from the rendered page (codec-proof); size/area filtering; best-effort with text-only fallback; this specific PDF is InDesign-produced and regular.
- **Image blocks perturbing narration or anchoring.** *Mitigation:* insert at page position mirroring EPUB image blocks; explicit test that image blocks are skipped by narration and excluded from the word stream.
- **Codex bridge may not expose `image_gen`.** *Mitigation:* the `imageFile` interface is bridge-agnostic; owner can generate the PNGs in Codex directly from the manifest.
- **Alignment fix touching hot timing code.** *Mitigation:* confidence-preserving change, TDD, full narration suite as regression net; ship only if this book's evidence shows a real coverage gap.

## Explicit No-Migration Confirmation

No new `Schema_Vxx`, no `registerMigration` entry, no edits under `Shared/Database/Migrations/`. Figures reuse `epub_block.image_path` + `pdf_block_page`; deck images reuse `flashcard.media_json`; the card change is view-only. This sidesteps the V35/V36 collision risk entirely.
