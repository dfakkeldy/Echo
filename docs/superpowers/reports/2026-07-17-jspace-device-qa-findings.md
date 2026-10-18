# J-Space Device QA — Findings Report (2026-07-17)

Overnight investigation of four issues reported from on-device testing of
*J-Space: Inside the Machine* (epub + m4b + alignment sidecar, iCloud
`Books/J-Space/`). Screenshots IMG_2430–2433. **Investigation only — no code
changed.** Each finding cites file:line on `nightly` (as of `a61064a4`).

## TL;DR

| # | Issue | Root cause | Severity |
|---|-------|-----------|----------|
| 1 | Sessions (clock) button crashes app | `@Environment(DatabaseService.self)` never injected on iOS; trap fires in `SessionsListView.load()` | Crash — shipped broken since 2026-06-23 |
| 2 | Chevron advances audio but not text | Chevron is an audio-only seek; text follow blocked by two independent gates (`autoScrollEnabled`, accordion expansion) | High UX |
| 3 | No way back to current position | Affordance exists (`arrow.down.to.line`) but hides with the auto-hiding header and reads as "download" | High UX / discoverability |
| 4 | Long-press menu "deprecated" items | Menu is mostly *not* deprecated; real problems are grouping, one redundant item, and two latent bugs | Medium UX + hygiene |
| 5 | Word-level alignment missing for this book | `word_timing` table empty for the book; sidecar words never materialized (discovery/import gaps) | High — flagship feature silently degraded |
| 6 | Word tap gives no feedback on which word | Confirmed: no tap-time word highlight exists at all | Medium UX |

---

## 1. Sessions button crash (IMG_2433)

**Root cause (confirmed, data-independent).**
[`SessionsListView.swift:9`](../../../EchoCore/Views/SessionsListView.swift)
declares `@Environment(DatabaseService.self)` (non-optional). The iOS root
(`EchoCore/EchoCoreApp.swift:104-108`) injects `model`, `settings`,
`storeManager`, `freeTierGate`, `autoExport` — **never `DatabaseService`**
(it lives on `PlayerModel.databaseService`). Only the macOS app injects it
(`Echo macOS/Echo_macOSApp.swift:73,284`), which is why the identical pattern
works there. On iOS the sheet appears, `.task → load()` reads
`dbService.writer` (`SessionsListView.swift:105`) and SwiftUI traps:
*"No Observable object of type DatabaseService found."*

- Introduced with the feature itself: `55ca0d13` (2026-06-23, unified-feed
  Phase 5). The injection never existed on iOS; every tap has crashed since.
- **Same latent crash one level deeper:** `SessionDetailFeedView.swift:11,44`
  — fixing only the list view moves the crash to tapping a session row.
- Empty-history theory ruled out: `SessionSummaryService`'s force-unwraps are
  guarded (`guard !segments.isEmpty`) and covered by
  `EchoTests/SessionSummaryServiceTests.swift` (incl. empty case). No test
  renders the *views*, which is exactly where the bug lives.

**Fix direction (not applied):** inject `.environment(dbService)` at the iOS
root once the DB exists, or pass the writer explicitly into both views
(matches the codebase's constructor-injection pattern). Add a render test that
instantiates each presentable sheet inside a minimal host.

## 2. Chevron chapter-skip desyncs text (IMG_2431/2432)

**Root cause (confirmed).** The header chevrons
(`ReaderTab.swift:61-73` prev / `:109-121` next) call
`PlayerModel.nextSection()` → `PlaybackController.seekToSection()`
(`PlaybackController.swift:580-593`) — **pure audio seek**, no
`activeBlockID`, no scroll trigger, no chapter expansion. Compare the TOC
path (`ReaderTab.swift:526-532` → `seekToBlockAndScroll` `:917-925`), which
does all three — that's why TOC navigation moves the text and chevrons don't.

Text follow is then blocked by two independent gates:

- **Gate A — follow mode:** any manual drag sets `autoScrollEnabled = false`
  (`ReaderFeedCollectionView.swift:742-746`); the scroll-on-active-block code
  guards on it (`:627`). Nothing in the chevron path re-arms it.
- **Gate B — accordion:** only one chapter's blocks are in the collection
  snapshot (`ReaderFeedViewModel.swift:109,134`); auto-expanding the newly
  playing chapter is gated on `isPlaying` (`:1053-1066`). If the target
  chapter is collapsed, the scroller early-returns because the block isn't in
  the snapshot (`ReaderFeedCollectionView.swift:613,617`).

**Fix direction:** treat chevron chapter-skip as an explicit navigation
intent — mirror the TOC path (expand target chapter + force-scroll + re-arm
follow), rather than hoping passive follow catches up.

## 3. "Back to now" affordance (IMG_2432/2433)

- Scroll-away **does** release follow mode today
  (`scrollViewWillBeginDragging`, `ReaderFeedCollectionView.swift:742-746`) —
  the behavior Dan expected is implemented.
- The return affordance **exists**: `arrow.down.to.line` button,
  a11y label "Scroll to current playback position"
  (`ReaderTab.swift:1086-1095`) → re-arms follow, expands the active chapter,
  force-scrolls (`:600-607`). Two failures:
  1. **Symbol semantics** — `arrow.down.to.line` reads as *download*, not
     *return to now*. Dan guessed the clock icon instead and hit the crash.
  2. **It hides when needed** — the button lives in the header row, and the
     header auto-hides on scroll-down (`ReaderTab.swift:267`,
     `ReaderFeedCollectionView.swift:769`). Scrolling away simultaneously
     disengages follow *and* removes the re-engage button.
- No "Now" pill / player-bar tap / gesture exists anywhere; never has
  (`git log -S` confirms only the one button, once repositioned in
  `0aea2723`).
- Dead code found: `ReaderHeaderView.swift` (has an equivalent button) has
  zero call sites.
- macOS has the inverse problem: always follows, no disengage, no affordance
  (`MacReaderFeedView.swift:171-176`).

**Fix direction:** Maps-style transient re-center pill ("Back to now"),
shown only while `autoScrollEnabled == false`, floating independent of the
header chrome; keep the header button but with an accurate symbol.

## 4. Long-press context menu (IMG_2430)

Menu built in `ReaderTab+Alignment.swift:307` (`buildContextMenu`), UIKit
`UIMenu`, no settings gate, iOS only (macOS has a smaller right-click menu,
`MacReaderFeedView.swift:479`).

**Verdict per item** (manual-alignment items co-evolved with the auto
pipeline — 2026-05-30/31 — and are *not* legacy; manual `anchor-<UUID>` rows
survive every auto-align re-run and take precedence):

| Item | Verdict |
|---|---|
| Look Up / Save word | KEEP — word actions (2026-06-29, vocabulary feature) |
| Auto-Align Chapters | KEEP but misplaced — book-level action in a paragraph menu |
| Change Color | KEEP — highlight/theming, not alignment |
| Align to Now / 5s Ago | KEEP — the manual fine-tune layer on top of auto-align (also fires background WhisperKit fine-tune) |
| Align to Chapter Start | **REDUNDANT** — Tier-0 `ChapterTitleMatcher` does this now; already absent from macOS menu |
| Not in Audio (Paragraph/Chapter) | KEEP — **essential**, only front-matter mechanism; pipeline can't infer it |
| Reset Alignment | KEEP as escape hatch — but it deletes *all* anchors incl. auto; naming/scoping worth revisiting |

**Latent bugs found in passing:**
- `alignBlock(_:to:source:)` ignores its `source:` parameter
  (`ReaderTab+Alignment.swift:14`) — "Align to Chapter Start" anchors are
  persisted mislabeled as `moveToNow`.
- `AlignmentService.anchorChapterStart/anchorChapterEnd` are dead (no callers
  outside tests).
- ARCHITECTURE.md still documents a nonexistent "Align to Chapter End" item.

## 5. Word-level alignment missing (IMG_2432)

**How word-level actually works:** there is **no mode/flag**. The reader
loads all `word_timing` rows unfiltered (`WordTimingDAO.swift:31-38`,
`ReaderFeedViewModel.swift:465-471`); if a row covers the current time in the
active block, the word is highlighted (`ReaderActiveBlockResolver.swift:51-61`,
`ReaderFeedCollectionView.swift:641-671`); if the table is empty for the
book, read-along silently degrades to block level. So this book's
`word_timing` is empty.

**The sidecar has full word data** (verified on disk: 755 blocks, per-word
start/end, portable `s<i>-b<j>` IDs, manifest QC `SIDECAR_OK`). It never
became rows. Pipeline gaps, ranked:

1. **Found-but-unresolved skips everything**
   (`DocumentImportFinalizer.swift:69-72`): if zero portable IDs resolve to
   local blocks, no anchors are written, no sidecar words applied, **and**
   the interpolated-words fallback recalc is skipped for audio imports
   (`duration != nil` guard at `:202-212`) → empty `word_timing`.
2. **Discovery is epub-keyed and sibling-blind on single-file picks**:
   sidecar lookup happens only in the document-finalize tail reached from the
   EPUB/PDF/Text scanners (`DocumentImportFinalizer.swift:383-418`); there is
   no check keyed to the m4b. Single-file picks on iOS cannot enumerate
   siblings (`SecurityScopeManager.swift:77-85` — parent scope fails);
   only a folder pick grants sibling access.
3. **Dataless iCloud sidecar is invisible**: an undownloaded sidecar is a
   hidden `.alignment.json.icloud` placeholder, and discovery uses
   `.skipsHiddenFiles` (`DocumentImportFinalizer.swift:392-396`). Very
   plausible for an iCloud folder browsed on iPhone.
4. Per-block word application also requires exact token-count match
   (`WordTimingMaterializer.swift:280`); mismatched blocks keep interpolated
   rows.

Rejected hypotheses: reader does *not* require a particular timing source
(no filter), and in-app auto-alignment would *change* word rows, not remove
them.

**Confirmation needed on device:** which of ranks 1–3 hit this import.
Quick user test: re-import by picking the **folder** (not the files) after
ensuring the sidecar is downloaded (no cloud icon) — if word highlighting
appears, discovery was the failure.

**Observability gap:** nothing in the UI shows whether a sidecar was
detected/applied or whether read-along is word- vs block-level — logs only
(`DocumentImportFinalizer.swift:70-95,188,267-269`). A user cannot tell.

## 6. Word-tap feedback (confirmed missing)

Tap resolves the word and seeks audio (`ReaderFeedCollectionView.swift:895-929`
→ `ReaderTab.swift:890-904`); long-press resolves the word only to title the
"Look Up/Save" actions (`:931-958`). **Neither path highlights the hit
word** — `applyWordHighlight` is driven exclusively by playback karaoke. When
the menu shows "Look Up ‹word›", the quoted title is the only indication of
what was hit.

---

## HIG assessment of the four screens

Reviewed against Apple HIG (clarity/consistency/deference, menus, feedback,
Dynamic Type, touch targets). Touch targets are fine (44 pt frames,
`readerHeaderButtonSize`), accessibility labels present on the header
buttons.

**IMG_2430 — context menu:**
- 10 flat items mixing word, paragraph, chapter, and book scopes violates
  menu-grouping guidance. Use `UIMenu` inline sections: word actions /
  appearance / paragraph alignment / chapter–book actions; destructive last
  (already correct).
- A book-level command ("Auto-Align Chapters") inside a paragraph context
  menu breaks the HIG expectation that context menus act on the pressed
  element — relocate to book scope (TOC sheet toolbar or Book Settings).
- Add a momentary highlight of the hit word when the menu opens (HIG "clear
  feedback"; also resolves issue 6).

**IMG_2433 — navigator/search header:**
- Crash aside, `clock.arrow.circlepath` is a reasonable *history* symbol, but
  four icon-only circular buttons in a row with non-obvious glyphs is the
  discoverability failure that caused the wrong-button tap. Consider moving
  Sessions into the overflow menu (consistent with the 2026-07-05 UI-cleanup
  direction of a single overflow menu).
- `arrow.down.to.line` for "scroll to current position" is semantically
  wrong (reads as download). Prefer a labeled transient pill ("Back to now")
  over any bare glyph; pill pattern = Maps re-center. Liquid Glass
  (`glassEffect`) is a natural fit for a floating pill on iOS 26.
- Header icons use hardcoded `.font(.system(size: 16))` — they won't scale
  with Dynamic Type; use text styles / `imageScale` instead.
- Two stacked filter systems (chips row + Whole book/Last session segmented
  control) is heavy chrome in a content-first reader; candidates for
  consolidation, low priority.

**IMG_2431/2432 — reader header chevrons:**
- Chevrons flanking a *title* signal content navigation; today they perform
  transport-only seeks. Aligning behavior with the affordance (issue 2 fix)
  is itself the HIG fix ("standard gestures work as expected").
- Two adjacent chevron pairs (part row vs chapter row) with different targets
  are ambiguous; worth a one-line label or merging.
- Auto-hiding header is good deference — provided the "Back to now"
  affordance stops living inside it (issue 3).

## Suggested priority order

1. **Crash fix** (env injection + both views + render test) — one-line-ish,
   ships alone.
2. **Sidecar word-timing import hardening** (m4b-keyed discovery, dataless
   iCloud download/retry, fallback recalc when sidecar unresolved, +
   surface "sidecar applied / word-level active" somewhere visible).
3. **Back-to-now pill + chevron = full navigation** (one coherent
   follow-mode PR).
4. **Context-menu regrouping** + drop "Align to Chapter Start", relocate
   "Auto-Align Chapters", tap-word flash.
5. Hygiene: `alignBlock` source bug, dead `ReaderHeaderView` /
   `anchorChapterStart/End`, stale ARCHITECTURE.md line.

## Verification notes

- No build/test run — investigation only, no code changed. All claims are
  file:line-cited from `nightly` source; crash root cause additionally
  corroborated by an independent second pass.
- On-device confirmation still needed for which sidecar gap (ranks 1–3) hit
  this specific import.
