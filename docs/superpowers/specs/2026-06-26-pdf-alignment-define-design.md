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
| D5 | Page word→geometry mapping | **Capture provenance at import** into a new **V26 `pdf_page_geometry`** table |
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
        └─▶ pdf_page_geometry rows           ← NEW (V26, M3)
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
| **M2** | Shared **render-layer migration** → define + Save + **word-tap-to-seek** (all card-feed books) | Active-word resolver, `word_timing`, `wordRanges` | `UILabel`→selectable TextKit host (iOS) / `NSTextView` host (macOS); edit-menu "Save word"; tap→seek; re-implement highlight on new host |
| **M3** | **In-place PDF-page** karaoke highlight + define-on-page | Active-word resolver, `word_timing` | V26 `pdf_page_geometry` capture; `PDFView` bbox overlay; page word hit-test |
| **M4** | **Vocabulary study card** + narrate-PDF affordance | `flashcard` table, study feed, FSRS, `.apkg` export | `cardType="vocabulary"` builder; review surfacing via Look Up; "Narrate PDF" entry point |

Recommended order: **M1 → M2 → M3 → M4** (M1 ships value almost immediately; M3 is the hardest and depends on no other milestone but is sequenced last among the highlight work).

---

## 5. Data model

### M1, M2 — no schema change
Reflow rendering and the selectable-host migration reuse `epub_block`, `alignment_anchor`, and `word_timing` exactly as narrated EPUB/text already do.

### M3 — new `pdf_page_geometry` table (V26)
Bridges our text-storage space to PDFKit's page-coordinate space. Captured at import while the **raw** page string is still in hand (before `TextDocumentParser` normalization), so it survives multi-column/hyphenation differences between `page.string` and our normalized block text.

```
CREATE TABLE pdf_page_geometry (
    id            INTEGER PRIMARY KEY,
    audiobook_id  TEXT NOT NULL,
    epub_block_id TEXT NOT NULL,
    page_index    INTEGER NOT NULL,   -- PDFDocument page index for this block
    char_start    INTEGER NOT NULL,   -- offset of block start in that page's RAW string
    char_len      INTEGER NOT NULL    -- length of the block's slice in the raw string
);
-- index on (audiobook_id, epub_block_id); index on (audiobook_id, page_index)
```
- Words are **derived at render** by the same deterministic whitespace split `WordTimingMaterializer` uses — no per-word rows needed.
- **Render mapping:** active word → char range within block → `+ char_start` → page char range → union `PDFPage.characterBounds(at:)` → page rect(s).
- **Migration caveat:** already-imported PDFs must be **re-imported** to populate geometry; until then page mode shows no overlay (reflow-mode highlight still works). Note in release notes.
- Run `schema-migration-reviewer` before committing — current max is **V25**; parallel branches could also claim V26 (collision risk).

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

**M2 — selectable render host** (shared by EPUB, text, PDF-reflow)
- **iOS:** `UILabel` → read-only, non-editable, **selectable `UITextView` (TextKit 2)** in `ParagraphCardCell`/`HeadingCardCell`. Gives `characterIndex(for:)` (touch → char → word via `wordRanges`), native long-press selection + **Look Up**, and a custom **"Save word"** edit-menu item (`UIEditMenuInteraction` / `editMenu(for:)`).
- **macOS:** SwiftUI `Text` → an `NSTextView`-backed representable with the same selectable + Look Up + custom-menu behavior.
- Re-implement on the migrated host (all from existing data):
  - **Read-along highlight** — current-word background on the text view's text storage (replaces `UILabel.applyWordHighlight`).
  - **Word-tap-to-seek (D3)** — tap → `characterIndex(for:)` → word index → `word_timing.audio_start_time` → seek.
  - **Define + Save** — long-press selects word → Look Up; callout "Save word" → vocabulary builder (§6.3).
- **Alternative considered:** manual word-frame precompute (measure each `wordRange`'s `boundingRect`, hit-test via gesture recognizer). Avoids the host swap but is fiddly with line wrapping and provides no native selection/Look Up — rejected.

### 6.2 PDF page — M3 (in-place highlight + define-on-page)

- **Import-time capture:** extend `PDFAutoImportScanner`'s per-page `.string` pass to emit `pdf_page_geometry` rows (§5).
- **Overlay:** `PDFDocumentView` gains an overlay driven by `ReaderActiveBlockResolver`:
  1. active word → char range in block → `+ char_start` → page char range,
  2. union `PDFPage.characterBounds(at:)` → page-space rect(s) (multi-line-fragment aware),
  3. convert page-space → view-space via `pdfView.convert(_:from: page)` → paint karaoke rect,
  4. **auto-follow:** when active block's `page_index` changes, navigate `PDFView` to that page, keep active word visible.
  - Cache geometry per active word (not per frame) to bound `characterBounds` cost.
- **Define / Save / seek on the page:** `PDFView` is natively selectable → long-press yields selection + Look Up free. Add word hit-test `page.characterIndex(at: point)` → reverse-map through `pdf_page_geometry` → block + word; reuse the **M2 "Save word" and seek builders** so both surfaces behave identically.
- **Scanned/image PDFs:** no `characterBounds` → overlay simply does not paint (and they have no narration). Graceful degradation, consistent with the OCR non-goal.

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
