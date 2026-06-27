# PDF Read-Along Highlighting + Press-and-Hold "Define" — Design

- **Date:** 2026-06-26
- **Status:** Approved (brainstorm) — ready for implementation planning
- **Author:** Dan Fakkeldy (with Claude)
- **Branch base:** `origin/nightly` (must include PR #183 "Add PDF narration support", commit `566f835`)
- **Predecessors:** [[unified-feed-initiative]], `2026-06-20-markdown-text-narration-import-design.md`, `2026-06-26-kokoro-synthesis-word-timing-design.md`

---

## 1. Summary

PDF narration already exists (PR #183): a PDF's born-digital text is extracted per page, pushed through the same block pipeline as EPUB/text, narrated on-device (Kokoro), and given **exact per-block synthesized anchors** plus **interpolated per-word timing**. The audio↔text timing is therefore *already solved* for narrated PDFs.

This initiative spends that timing on two user-facing features:

1. **Read-along highlighting for narrated PDFs**, on two reading surfaces:
   - **Page mode** (default): the real `PDFView`, with an in-place karaoke highlight painted on the page.
   - **Reflow mode**: the PDF's blocks rendered in the shared card feed, reusing the existing word-by-word read-along highlight.
2. **Press-and-hold "Define"**: long-press a word → native **Look Up** popover, plus a **"Save word"** action that mints an FSRS **vocabulary flashcard** anchored to the block + audio timestamp (with the narrated audio snippet attached). This is delivered across *every* card-feed book (EPUB, text, PDF-reflow) and on the PDF page.

A single shared render-layer upgrade (non-selectable `UILabel`/`Text` → selectable TextKit host) underpins define, "Save word", and the long-deferred **word-tap-to-seek** — all at once.

**Explicitly out of scope:** DTW/WhisperKit/VAD alignment (not needed for synthesized audio), OCR for scanned PDFs, and storing dictionary text on cards (no public Apple API).

---

## 2. Background — current state (grounded in `nightly`)

### Narrated PDFs already produce timing data
- `PDFAutoImportScanner` (`EchoCore/Services/PDFAutoImportScanner.swift`) extracts born-digital text via `PDFDocument(url:).page(at:).string` and feeds it through `TextDocumentParser` → `DocumentImportFinalizer`, creating `epub_block` rows — "the same EPUB block pipeline used for EPUB."
- `PlayerLoadingCoordinator` (`:215`, `:224`) calls `PDFAutoImportScanner.importPDFFile` / `scanAndImportIfNeeded` **on load**, so a PDF book's blocks exist on-device whenever it is opened.
- Narration of those blocks produces **exact per-block** `synthesized` anchors (`NarrationService.swift:131-173`), then `WordTimingMaterializer` interpolates per-word `[start,end)` rows across each block's known span — identical to narrated EPUB/text. **No DTW.**

### The gap is the *page* surface, not the highlight (corrected 2026-06-26)
`RootTabView.swift` (`:186-189` as of `nightly` @ #199) branches the Read tab:
```
if model.hasEPUB        → ReaderTab          (card feed; DOES word-by-word highlight)
else if model.hasPDF    → PDFDocumentView    (visual pages; NO highlight surface)
else if hasStandaloneTranscript → …
```
**Critical correction:** `hasEPUB` is *not* an `.epub`-file check — it is `EPubBlockDAO.visibleBlocks(audiobookID).isEmpty == false` (`PlayerTimelinePersistenceService.hasEPUB`). A PDF opened as an audioless study book is parsed into **visible** `epub_block` rows on load (`PlayerLoadingCoordinator.importDocumentForAudiolessBook` → `PDFAutoImportScanner.importPDFFile` → `DocumentImportFinalizer.finalize`). So a narrated/parsed PDF has `hasEPUB == true` and the branch short-circuits to **`ReaderTab` — the card feed, *with* read-along highlighting** — and **never reaches `PDFDocumentView`**. `ReaderTab` renders purely from `epub_block`/`word_timing` rows and is format-agnostic.

**Consequence:** for a narrated PDF, the highlightable **card feed (reflow) already works today**. The genuinely unreachable surface is the **visual PDF page** (`PDFDocumentView` is only shown for a PDF with *no* blocks — a companion PDF alongside *external* audio, or a scanned/no-text PDF). The data exists *and* the reflow highlight already reaches it; what's missing is (a) the visual page surface for a parsed PDF, and (b) the in-place highlight *on* that page (M3).

### Per-word interaction is blocked on both surfaces
- Card feed: `ParagraphCardCell`/`HeadingCardCell` draw an `NSAttributedString` in a **non-selectable `UILabel`** (iOS) / SwiftUI `Text` (macOS). `wordRanges: [NSRange]` exist for karaoke tinting but only in logical index space — no glyph geometry, so a touch cannot resolve to a word.
- PDF page: `PDFDocumentView` renders pages; long-press currently only captures a page-state screenshot bookmark. No word highlight, no word hit-test wired to our model.

### No existing dictionary/define feature
"Dictionary" in the codebase is the TTS **pronunciation override** store — unrelated. There is no lookup, popover, or Look Up action.

---

## 3. Decisions (locked during brainstorming)

| # | Decision | Choice |
|---|----------|--------|
| D1 | Highlight surface | **Hybrid** — visual page (default) + reflow text-feed mode. *Note: today a parsed PDF already defaults to the reflow feed (see §2); making page the default is a deliberate behavior change.* |
| D2 | Define UX | **Look Up popover + Save-to-study** (FSRS vocabulary flashcard) |
| D3 | Per-word render scope | **Whole shared card feed** (EPUB/text/PDF-reflow) **+ ship word-tap-to-seek** |
| D4 | In-place PDF-page highlight | **In v1** (premium hybrid) |
| D5 | Page word→geometry mapping | ~~Capture char-offset provenance at import (`pdf_page_geometry`)~~ **REVISED 2026-06-27 (§5): infeasible — shared-parser normalization destroys offsets. Now: capture per-block PAGE INDEX (`pdf_block_page` V26) + locate the word at render via PDFKit text search.** |
| D6 | Vocabulary cards vs Pro cap | **Count against the flashcard cap** (they are real study cards) |
| D7 | Duplicate "Save word" | **Dedupe per `(audiobookID, lowercased word)`**, re-surface existing card |

---

## 4. Architecture

### Reader surface model (the hybrid)
For a PDF book, the Read tab gains a **page ⇄ reflow** toggle:
- **Page mode** → `PDFDocumentView` + in-place karaoke overlay (M3).
- **Reflow mode** → the shared card feed rendered from the PDF's blocks (M1), with the existing read-along highlight.

### Shared engine, new surfaces
Everything is driven by the existing `ReaderActiveBlockResolver` (audio time → active block → active word). Only the *surfaces* and the *interaction layer* are new.

```
PDF ─▶ PDFAutoImportScanner (born-digital text + raw page offsets)
        ├─▶ epub_block rows
        └─▶ pdf_block_page rows (page index) ← NEW (V26, M3; was pdf_page_geometry)
   ─▶ NarrationService ─▶ synthesized anchors ─▶ WordTimingMaterializer ─▶ word_timing
   ─▶ ReaderActiveBlockResolver (audio time → active block → active word)
        ├─▶ card-feed cell highlight          (M1 reflow; M2 selectable host)
        └─▶ PDF-page bbox overlay             (M3, via pdf_page_geometry)
   ─▶ press-hold word ─▶ Look Up + "Save word" ─▶ vocabulary Flashcard (M4)
   ─▶ tap word ─▶ seek to word.audio_start_time (M2)
```

### Milestones (each independently shippable & testable)

| # | Milestone | Reuses | New work |
|---|-----------|--------|----------|
| **M1** | PDF **page surface reachable** + **page ⇄ reflow toggle** + default (reflow+highlight already works via `hasEPUB`→`ReaderTab`, see §2) | Existing card-feed highlight path (reflow), `PDFDocumentView` (page) | Detect a parsed PDF (`hasPDF && hasReflowableBlocks`); host both surfaces behind a per-book toggle; choose/persist default (D1: page); pure `ReaderSurfaceMode` resolver |
| **M2** | Per-word interaction on the card feed → define + Save + **word-tap-to-seek** (iOS) | Existing block tap-to-seek + `contextMenuConfigurationForItemsAt:point:` menu; `word_timing`/`wordCache`; `wordRanges` | `UILabel`→**non-selectable** read-only `UITextView` (TextKit, for hit-testing only); `wordIndex(at:)`; **augment** the existing context menu with word "Look Up"+"Save"; refine tap block→word. *(Revised 2026-06-27 — see §6.1.)* |
| **M3** | **PDF-page** auto-follow + best-effort word karaoke + define-on-page | Active-word resolver, `word_timing`, M2 builders | V26 `pdf_block_page` (page-index) capture; `PDFView` page auto-follow; search-based word highlight (on-device-tuned); long-press define-on-page *(REVISED — see §5/§6.2)* |
| **M4** | **Vocabulary study card** + narrate-PDF affordance | `flashcard` table, study feed, FSRS, `.apkg` export | `cardType="vocabulary"` builder; review surfacing via Look Up; "Narrate PDF" entry point |

Recommended order: **M1 → M2 → M3 → M4** (M1 ships value almost immediately; M3 is the hardest and depends on no other milestone but is sequenced last among the highlight work).

---

## 5. Data model

### M1, M2 — no schema change
Reflow rendering and the selectable-host migration reuse `epub_block`, `alignment_anchor`, and `word_timing` exactly as narrated EPUB/text already do.

### M3 — new `pdf_block_page` table (V26) — REVISED 2026-06-27

**Why the original `pdf_page_geometry` (char-offset) design was dropped:** the PDF→text pipeline (`PDFAutoImportScanner.extractText` → `parsePDFText` → `TextDocumentParser.buildParse`) **concatenates pages** (`ExtractedText.body` joins with `"\n\n"`) and **reflows/normalizes lines into paragraphs before blocks are created**, so per-block raw char offsets are destroyed in a *shared* parser (also used by EPUB/text). Worse, the normalized block text does not index 1:1 into `page.string`, which `PDFPage.characterBounds(at:)` requires — so stored char offsets wouldn't reconcile even if captured. The robust mechanism is the inverse of D5's original choice.

**Revised:** capture only the **page index** per block (cleanly recoverable from the still-separated `ExtractedText.pages` before concatenation), and locate the active word on the page at render via **PDFKit text search** (`PDFDocument/PDFPage.findString` / `page.selection(for:)`), which is inherently tolerant of the whitespace/normalization differences.

```
CREATE TABLE pdf_block_page (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    audiobook_id  TEXT NOT NULL,
    epub_block_id TEXT NOT NULL,
    page_index    INTEGER NOT NULL   -- 0-based PDFDocument page this block came from
);
-- index on (audiobook_id, epub_block_id); index on (audiobook_id, page_index)
```
- **Capture point:** hook `parsePDFText` at the `ExtractedText.pages` level (pages still separated), tagging each emitted block with its source page index, persisted after `DocumentImportFinalizer`.
- **Render mapping (page-level, robust):** active block → `pdf_block_page.page_index` → `PDFView.go(to: page)` auto-follow.
- **Render mapping (word-level, best-effort):** active word's text + a small context window → `PDFPage.findString`/`selection` on that page → selection bounds → `pdfView.convert(_:from: page)` → karaoke rect. Best-effort and on-device-tuned; falls back to page-level follow when the search is ambiguous or misses.
- **Migration caveat:** already-imported PDFs must be **re-imported** to populate `pdf_block_page`; until then page mode auto-follows by best-effort search only (reflow-mode highlight still works). Note in release notes.
- Run `schema-migration-reviewer` before committing — current max is **V25**; parallel branches could also claim V26 (collision risk).
- **Verifiability:** the V26 schema + page-index capture are build+unit-testable; the overlay/auto-follow/search-highlight are runtime-only and require on-device verification.

### M4 — vocabulary card: no migration
`Flashcard` (`Shared/Database/Flashcard.swift`) already carries every needed field:

| Field | Vocabulary use |
|-------|----------------|
| `frontText` | the word |
| `backText` | **empty** (no stored definition — see §7); review fetches via Look Up |
| `mediaTimestamp` / `endTimestamp` | word's `audio_start_time` / `audio_end_time` → narrated audio snippet |
| `sourceBlockID` | block anchor |
| `audiobookID` | the book |
| `cardType` | new `StudyFlashcardType.vocabulary = "vocabulary"` (`Shared/Study/StudyPlanTypes.swift`) |
| `triggerTiming` | `.manualOnly` |
| `tags` | optional; sentence context can also be stored here or appended to `backText` |

- Flows into the study feed as the existing `ReaderCardItem.ankiCard(Flashcard)` — no new feed plumbing.
- Exports via the existing `.apkg` path (`ApkgExportService` / `MacApkgExportService`).
- **Dedupe (D7):** before insert, look up an existing `vocabulary` card for `(audiobookID, lower(frontText))`; if found, re-surface it instead of inserting.
- **Pro cap (D6):** counts against `PaywallContext.flashcardCap` like any flashcard.

---

## 6. Per-surface design

### 6.1 Card feed & the page/reflow toggle — M1 + M2 (selectable host)

**M1 — page surface reachable + page ⇄ reflow toggle** (the reflow card feed + highlight already works — see §2; M1 makes the *page* reachable and lets the user choose):
1. Add `hasReflowableBlocks` to `PlayerModel` (mirrors `hasEPUB`: `EPubBlockDAO.count(for:) > 0`), and a pure `ReaderSurfaceMode` resolver: a parsed PDF (`hasPDF && hasReflowableBlocks`) offers `[.page, .reflow]`; everything else keeps today's single surface.
2. For a parsed PDF, render the **chosen** surface (page → `PDFDocumentView`; reflow → `ReaderTab`) instead of letting `hasEPUB` silently force the feed. Add a **page ⇄ reflow** toggle (segmented control in `UnifiedTopHeader`, shown only when the resolver returns both modes).
3. Persist the choice per book (extend `BookSettingsOverrideStore` / `BookPreferencesService`, key `readerPDFViewModeKey`); default = **page** (D1).
4. The existing `ReaderActiveBlockResolver` → cell highlight path is reused unchanged in reflow mode — no engine work.

**M2 — per-word interaction (REVISED 2026-06-27, iOS card feed only)**

The original plan (selectable `UITextView` + native selection "Look Up") was **dropped after implementation-time discovery**: the reader's block interactions are *collection-view-mediated* (`ParagraphCardCell`/`HeadingCardCell` are passive; tap → `ReaderFeedCollectionView.didSelectItemAt` → seek-to-block; long-press → `contextMenuConfigurationForItemsAt:point:` → `buildContextMenu(block:)`). A *selectable* `UITextView` installs selection gestures that intercept and break both. The revised approach is additive and reuses that infrastructure:

- **Render host:** `UILabel` → a **non-selectable**, non-scrolling, read-only `UITextView` in both cells — used *only* to gain TextKit hit-testing (`closestPosition(to:)`/`characterIndex(for:)`). `isSelectable=false`, `isEditable=false`, `isScrollEnabled=false`, `textContainerInset=.zero`, `lineFragmentPadding=0`, clear background. All existing rendering preserved (attributed string, search highlight, `applyWordHighlight` via `textView.attributedText`, `lineSpacing`, colors, `isActiveBlock`). No selection gestures installed → no conflict with the collection view.
- **Hit-test:** add `func wordIndex(at point: CGPoint) -> Int?` to the cell (text-view layout → char index → word via `wordRanges`).
- **Define + Save (via the EXISTING long-press menu):** `contextMenuConfigurationForItemsAt:point:` already supplies the touch point. Resolve it to a word; when it does, **prepend** two actions to `buildContextMenu(block:)`: **"Look Up '<word>'"** → present `UIReferenceLibraryViewController(term:)` (the same on-device dictionary, gated by `dictionaryHasDefinition(forTerm:)`; no text selection needed), and **"Save '<word>'"** → `cardType="vocabulary"` flashcard (respecting `FreeTierGate` cap (D6) + dedupe (D7)).
- **Word-tap-to-seek (D3):** refine the existing tap from block→word granularity via a tap gesture that resolves the word at the tap location and seeks to `word_timing.audio_start_time` (fallback to block seek). The one genuinely new gesture — kept last in the plan so it can't block define/Save.
- **macOS:** unchanged. The Mac reader (`MacReaderFeedView`) is pure SwiftUI `Text`/`AttributedString` — a separate render path; M2 is **iOS-only** (parity is a follow-up).
- **Look Up note:** `UIReferenceLibraryViewController` is the same on-device dictionary the selection "Look Up" presents; only the *trigger* differs (a menu action instead of the selection callout). D2's intent (on-device dictionary popover) is preserved.

### 6.2 PDF page — M3 (in-place highlight + define-on-page) — REVISED 2026-06-27

- **Import-time capture:** hook `PDFAutoImportScanner.parsePDFText` at the `ExtractedText.pages` level (pages still separated, before concatenation) to tag each emitted block with its source page index, persisted into `pdf_block_page` (§5) after `DocumentImportFinalizer`. *(Build + unit-testable.)*
- **Overlay (`PDFDocumentView`) driven by `ReaderActiveBlockResolver`:** the view builds its own observer of `model.currentPlaybackTime` (mirroring `ReaderTab`'s `.onChange`), loads `WordTimingDAO.words(forAudiobook:)` + the timeline cache once, and resolves the active (blockID, wordIndex):
  1. **Page auto-follow (robust):** active block → `pdf_block_page.page_index` → `PDFView.go(to: page)` so the page tracks narration.
  2. **Word karaoke (best-effort):** active word's text + a short context window → `PDFPage.findString`/`selection(for:)` on that page → selection `bounds(for: page)` → `pdfView.convert(_:from: page)` → paint the karaoke rect. Throttled; cached per active word. Falls back to page-level follow when the search is ambiguous/misses. *(Runtime-only — on-device verification + tuning required.)*
- **Define / Save on the page:** reuse the existing `PDFKitView` long-press (`handleLongPress`). Read the word *directly from the PDF* at the press point via `page.selection(for:)` / `page.character(at:)` → present **Look Up** (`UIReferenceLibraryViewController`, M2's `DictionaryLookupPresenter`) and **Save** (M2's `VocabularyCardBuilder` + cap + dedupe; audio time from the resolved active block when the exact word time is unavailable).
- **Scanned/image PDFs:** `page.string` is empty → no blocks, no narration, no overlay. Graceful no-op, consistent with the OCR non-goal.

### 6.3 Define + Save-to-study UX — M4

- **Gesture (identical on both surfaces):** long-press a word → native **Look Up** popover (on-device, offline, multi-language). Same callout carries **"Save word"**.
- **"Save word" builds** a `Flashcard` per §5 (M4). The **containing sentence** is segmented from the block text and stored as context.
- **Review & feed:** flows in as `ReaderCardItem.ankiCard`, scheduled by FSRS, exported via `.apkg`. Review = see word + play its narrated snippet + tap **Look Up** to check meaning + grade. Distinct vocabulary styling deferred.
- **Narrate-PDF affordance:** add a UI entry point to narrate a PDF book (e.g. a "Narrate" action in the PDF book's reader/settings) so on-device users reach the narrated-PDF → highlight → define flow without echo-cli. (The blocks are parsed on load; this triggers synthesis.)

---

## 7. Non-goals & boundaries (v1)

- **OCR for scanned PDFs** — no extractable text → page-only, no narration/highlight. Deferred.
- **Storing dictionary text on cards** — there is **no public API** that returns Look Up's definition text (`DCSCopyTextDefinition` is macOS-only/semi-private; iOS has none). Cards store word + context + audio + anchor; the definition is surfaced via Look Up on demand. `backText` stays empty by design.
- **DTW refinement of narrated word timing** — interpolation matches what narrated EPUB ships; synthesized block bounds are already exact.
- **Bespoke vocabulary-card styling** — reuse `.ankiCard` rendering.
- **watchOS / Widget / CarPlay reader surfaces** — unaffected (no reader text surface).

---

## 8. Cross-platform parity

The render-host migration diverges by platform (iOS `UITextView` / macOS `NSTextView`). M2 and M3 must go through the `cross-platform-parity-reviewer` before merge. watchOS, Widget, and CarPlay carry no reader text surface and need no change.

---

## 9. Risks

- **M2 (highest):** swapping the cell text host can regress scroll performance, Dynamic Type, VoiceOver, and the existing karaoke tint. Mitigate with `swiftui-performance` + `accessibility` auditors and on-simulator verification before merge.
- **M3 reconciliation:** multi-column/hyphenated PDFs — mitigated by import-time raw-offset capture (D5).
- **M3 cost:** `characterBounds` per word — cache per active word, not per frame.
- **M3 coordinates:** PDFKit page→view conversion correctness; verify on multi-page, scrolled, and zoomed states.
- **M3 migration:** `pdf_page_geometry` needs a **re-import** of already-imported PDFs; older PDFs degrade to reflow-only highlight until re-imported. Document in release notes.
- **V26 collision:** parallel branches may also add V26 — confirm version at commit time.

---

## 10. Testing strategy

CI gate is build-only on this repo; `make build-tests` requires `CODE_SIGNING_ALLOWED=NO`.

- **Unit:**
  - `SchemaV26Tests` — migration up + idempotency.
  - Geometry capture — raw-offset correctness on a fixture PDF (incl. a multi-paragraph page), reusing `TestPDFFixture` (added by PR #183).
  - Vocabulary-card builder — field mapping, audio snippet from `word_timing`, dedupe (D7), cap (D6).
  - Sentence-context segmentation.
- **On-simulator verification (not unit-testable):** selection, Look Up, "Save word", tap-to-seek, page overlay tracking + auto-follow — per milestone.
- **Pre-commit agents:** `schema-migration-reviewer` (V26), `cross-platform-parity-reviewer` (M2/M3), plus `swiftui-performance` + `accessibility` for M2.

---

## 11. Documentation to update (per CLAUDE.md doc-sync)

Run the `doc-sync` skill when implementation lands; update:
- `ARCHITECTURE.md` — reader-surface modes (page/reflow), `pdf_page_geometry`, vocabulary card type, the per-word interaction layer.
- `README.md` — feature surface (PDF read-along + define + vocabulary capture).
- `CHANGELOG.md`, `ROADMAP.md`.

---

## 12. Branch / base note

This work must be based on `origin/nightly` (carries PR #183). The implementation branch was rebased onto `origin/nightly` during brainstorming. Default PR target is **`nightly`** (never `main`/`weekly`). Per-milestone PRs are reasonable given the four independently-shippable milestones.

---

## 13. Future work (post-v1)

- OCR (Vision) for scanned PDFs → blocks → narration → highlight.
- DTW refinement of narrated word timing for tighter sync (optional).
- Distinct vocabulary-card rendering in the study feed.
- A bundled offline dictionary to populate card backs (removes the Look Up-only limitation).
- Word-tap-to-seek and define on the EPUB/text surfaces ride along automatically once M2 lands (already in scope), but bear separate verification.
