# Read-Along Karaoke — Stuck Last Word + Font-Shift Fixes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

> **Status:** PLAN ONLY — no code changed in the introducing PR.

**Goal:** Fix two read-along (karaoke) defects: (1) the last word of a paragraph card stays highlighted after playback moves on; (2) the highlighted word changes font weight (causing a visible typeface/metrics shift and reflow). Highlight should be color/background only and should clear correctly at paragraph boundaries.

**Architecture:** The data layer is already correct (`ReaderActiveBlockResolver.activeWord` returns `nil` past a paragraph's words). Both bugs are in the view layer. Bug 1 is iOS-only: the imperative retint path applies the highlight to the new cell but never clears the previously-highlighted cell. Bug 2 exists on both iOS and macOS: the highlight adds a heavier font weight on top of the background tint.

**Tech Stack:** Swift, UIKit (iOS cells), SwiftUI (macOS reader), Swift Testing.

## Root causes (verified)

**Bug 1 — last word stuck (iOS).** `ReaderFeedCollectionView.Coordinator.updateActiveWord` only looks up and retints the cell of the *new* `activeWord.blockID`, and its `guard let word … else { return }` returns without clearing anything when the active word becomes `nil` or moves to another block ([ReaderFeedCollectionView.swift:380-398](EchoCore/Views/ReaderFeedCollectionView.swift)). Adjacent paragraphs are usually both on-screen, so when the active word crosses A→B, B lights up but A keeps its stale highlight. The sibling `updateActiveBlock` *does* loop visible cells and reset state ([ReaderFeedCollectionView.swift:340-344](EchoCore/Views/ReaderFeedCollectionView.swift)); the word retint has no such reset. The ~12 Hz throttle ([ReaderFeedCollectionView.swift:162-168](EchoCore/Views/ReaderFeedCollectionView.swift)) can also swallow the final `nil` tick. The data is correct: `ReaderActiveBlockResolver.activeWord` returns `nil` when no word's `[start,end)` covers the time ([ReaderActiveBlockResolver.swift:45-55](Shared/ReaderActiveBlockResolver.swift)), and `applyWordHighlight(nil,…)` already resets to base text cleanly ([ParagraphCardCell.swift:161-173](EchoCore/Views/Cells/ParagraphCardCell.swift)).

**Bug 2 — font shift (iOS + macOS).** The highlight adds a `.semibold` font run *in addition* to the background tint:
- iOS: `UIFont.systemFont(ofSize: baseFont.pointSize, weight: .semibold)` ([ParagraphCardCell.swift:168-171](EchoCore/Views/Cells/ParagraphCardCell.swift)); identical in `HeadingCardCell.swift:167-170`.
- macOS: `result[…].font = .body.weight(.semibold)` ([MacReaderFeedView.swift:382-383](Echo macOS/Views/MacReaderFeedView.swift)).
Regular→semibold are different glyph metrics, so the word (and the rest of the line) reflows on every word transition — the jarring change reported. (The comment at `ReaderFeedCollectionView.swift:388-389` claims metrics are preserved; that's only true of the *base* font passed in — the cell then overrides the weight.)

macOS Bug 1 is **latent/mitigated**: each `MacBlockCardView` receives `activeWordIndex = block.id == currentBlockID ? activeWord?.index : nil` ([MacReaderFeedView.swift:74-75](Echo macOS/Views/MacReaderFeedView.swift)), so SwiftUI clears the inactive card declaratively — *provided* `currentBlockID` advances on the boundary. Verify on device; if `currentBlockID` lags, the same stale highlight could appear.

## Decisions made while you slept (override freely)

- **Bug 1 fix = "track last highlighted block, clear it" (minimal).** Mirror the spirit of `updateActiveBlock` but cheaper: keep `lastHighlightedBlockID`; on each tick, if it differs from the new word's block (or the new word is `nil`), clear the old cell via `applyWordHighlight(nil, …)`; remove the early-out so a `nil` word still clears. Also ensure a transition *to* `nil` is never throttled away.
- **Bug 2 fix = color/background only, no weight change.** Delete the `.font … .semibold` attribute at all three sites; keep the background tint. If a stronger active cue is wanted, add a `foregroundColor`/`foregroundStyle` change (color is metric-neutral) — never a weight change.
- **Highlight clears during inter-word gaps** (honor the data's `nil`), rather than holding the last word lit. Cleaner and matches the "moved on" expectation; flip to hold-last if you prefer a smoother feel (Open Q).
- **Fix both platforms together** for parity (macOS gets the Bug 2 font removal regardless; verify Bug 1 there).

## Open questions for Dan
1. With weight removed, is the translucent background enough contrast, or also tint the active word's foreground color? (Color is metric-safe.)
2. Clear during inter-word gaps (strict, chosen) vs hold-last-word until the next starts (smoother)?
3. Can you confirm on-device whether macOS already clears the previous paragraph (it should, via per-card `nil` gating)? Determines whether macOS needs only the font fix or both.

## Global Constraints
- Branch target **`nightly`**. Cross-platform change → run `cross-platform-parity-reviewer`; the two readers (iOS `ParagraphCardCell`/`HeadingCardCell`, macOS `MacReaderFeedView`) must not drift.
- iOS cells are UIKit (`EchoCore/Views/Cells`, iOS-only); macOS reader is separate SwiftUI. No watch/widget karaoke surface.
- Tests via `make build-tests` + `make test-only FILTER=…`. UI tests excluded from the scheme — prefer pure logic tests.

## File Structure
- `EchoCore/Views/ReaderFeedCollectionView.swift` — **modify**: `updateActiveWord` clears the previous cell; throttle never drops a `→ nil`.
- `EchoCore/Views/Cells/ParagraphCardCell.swift` + `HeadingCardCell.swift` — **modify**: drop the `.semibold` font attribute in `applyWordHighlight`.
- `Echo macOS/Views/MacReaderFeedView.swift` — **modify**: drop the `.semibold` font on the highlight run.
- `EchoTests/ReaderActiveWordTests.swift` — **modify**: add the "just past last word → nil" case.
- (New, optional) a tiny pure decision helper + test for the clear/apply choice.

---

### Task 1: Stop the last word staying highlighted (iOS)

**Files:**
- Modify: `EchoCore/Views/ReaderFeedCollectionView.swift:380-398` (`updateActiveWord`), and the throttle at `:162-168`.
- Test: `EchoTests/ReaderActiveWordTests.swift`; optional new pure-helper test.

**Interfaces:**
- Consumes: `activeWord: (blockID, index)?` from `ReaderFeedViewModel`; `ParagraphCardCell.applyWordHighlight(_:baseFont:)` / `HeadingCardCell.applyWordHighlight(_:baseFont:)`.
- Produces: at most one highlighted word across all visible cells; full clear when `activeWord == nil`.

- [ ] **Step 1: Failing/clarifying data test** — assert the resolver says "no active word" just past the last word (isolates the bug to the view). Add to `ReaderActiveWordTests`:

```swift
@Test func noActiveWordPastLastWord() {
    // block whose last word ends at 2.0; querying t = 2.0 with that block active → nil
    let result = ReaderActiveBlockResolver.activeWord(in: cache, time: 2.0, activeBlockID: "b1")
    #expect(result == nil)
}
```

- [ ] **Step 2:** Run → should already pass (data layer correct). This documents the invariant the view must honor.
- [ ] **Step 3 (optional but recommended): extract a pure decision** `KaraokeHighlightDecision(previousBlockID:newWord:)` → `(clearBlockID: String?, applyBlockID: String?, applyIndex: Int?)`, unit-tested like the codebase's other pure decisions (e.g. `MacBookmarkLoopDecision`). Cases: same block new index; block changed (clear old, apply new); new word nil (clear old, apply none).
- [ ] **Step 4:** Implement in `updateActiveWord`: track `lastHighlightedBlockID`; clear the previous cell before applying; remove the blanket early-out. Illustrative:

```swift
func updateActiveWord(_ word: (blockID: String, index: Int)?, in cv: UICollectionView) {
    if let prev = lastHighlightedBlockID, prev != word?.blockID,
       let ip = dataSource?.indexPath(for: "b-\(prev)"),
       let cell = cv.cellForItem(at: ip) {
        (cell as? ParagraphCardCell)?.applyWordHighlight(nil, baseFont: bodyFont)
        (cell as? HeadingCardCell)?.applyWordHighlight(nil, baseFont: headingFont)
    }
    lastHighlightedBlockID = word?.blockID
    guard let word, let ds = dataSource,
          let ip = ds.indexPath(for: "b-\(word.blockID)"),
          let cell = cv.cellForItem(at: ip) else { return }   // previous already cleared
    (cell as? ParagraphCardCell)?.applyWordHighlight(word.index, baseFont: bodyFont)
    (cell as? HeadingCardCell)?.applyWordHighlight(word.index, baseFont: headingFont)
}
```

- [ ] **Step 5:** Ensure a change *to* `activeWord == nil` is processed immediately (don't let the 12 Hz throttle drop the clearing tick) — e.g. bypass the throttle when the new value is `nil` or the block changed.
- [ ] **Step 6:** On-device check (Dan): play across a paragraph boundary; the previous card's last word clears as the next word lights up.
- [ ] **Step 7: Commit:** `git commit -m "fix(read-along): clear the previous word highlight on paragraph boundary (iOS)"`

### Task 2: Keep the font stable when highlighting (iOS)

**Files:**
- Modify: `EchoCore/Views/Cells/ParagraphCardCell.swift:165-171` and `EchoCore/Views/Cells/HeadingCardCell.swift:164-170`.
- Test: a logic test asserting the highlighted run's font equals the base font.

**Interfaces:**
- Produces: `applyWordHighlight` that adds only `.backgroundColor` (and optionally `.foregroundColor`) over the active range — no `.font` attribute.

- [ ] **Step 1: Failing test** — after highlighting, the `.font` over the active range equals the base font (weight unchanged); only `.backgroundColor` differs. Also assert metric stability: bounding width is unchanged with vs without the highlight.

```swift
@Test func highlightDoesNotChangeFont() {
    let cell = ParagraphCardCell()
    cell.configure(/* base text, regular body font */)
    cell.applyWordHighlight(1, baseFont: bodyFont)
    let attr = cell.currentAttributedText  // expose for test
    let runFont = attr.attribute(.font, at: rangeOfWord1.location, effectiveRange: nil) as? UIFont
    #expect(runFont == bodyFont)  // not semibold
}
```

- [ ] **Step 2:** Run → fails (current code applies semibold).
- [ ] **Step 3:** Delete the `.font … weight: .semibold` `addAttribute` in both cells; keep the `.backgroundColor` add. (Optionally add a `.foregroundColor` tint for extra contrast — metric-neutral.)
- [ ] **Step 4:** Run → passes; `make test` green.
- [ ] **Step 5: Commit:** `git commit -m "fix(read-along): highlight via color only, keep word font stable (iOS)"`

### Task 3: macOS parity — remove the highlight font shift

**Files:** Modify `Echo macOS/Views/MacReaderFeedView.swift:382-383`.

- [ ] **Step 1:** Remove `result[lower..<upper].font = .body.weight(.semibold)`; keep `.backgroundColor`.
- [ ] **Step 2:** On-device check (Dan, macOS): highlight no longer reflows; **also confirm whether the previous paragraph clears** (Bug 1 on macOS). If it doesn't, apply the same "clear on `currentBlockID` change" gating fix here.
- [ ] **Step 3: Commit:** `git commit -m "fix(read-along): macOS highlight color-only, keep font stable (parity)"`

---

## Self-review notes
- **Spec coverage:** stuck last word → Task 1 (+ Task 3 verify on macOS); font shift → Task 2 + Task 3. Both bugs, both platforms.
- **No placeholders:** all file:line concrete; `applyWordHighlight(nil,…)` confirmed to clear cleanly at `ParagraphCardCell.swift:162-173`.
- **Type consistency:** `applyWordHighlight(_:baseFont:)`, `updateActiveWord`, `ReaderActiveBlockResolver.activeWord` match the codebase.
- **Risk:** low and isolated to view rendering. The pure-decision extraction (Task 1 Step 3) makes the boundary logic testable without UIKit. No data-layer change.
