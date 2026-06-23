# Read-Along — Tap a Card to Seek + Play Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

> **Status:** PLAN ONLY — no code changed in the introducing PR.

**Goal:** Tapping a paragraph card in the read-along view seeks the audio to that paragraph and starts playing — with clear feedback when a card has no audio timing yet.

**Architecture:** A tap handler is already wired on both platforms, but it calls the wrong (low-level) seek that doesn't refresh UI or start playback, silently no-ops for blocks with no timing, and doesn't highlight the tapped card. The fix routes the tap through the canonical user-seek (`PlayerModel.seek(toSeconds:)`), explicitly starts playback, sets the active block, and adds a no-time fallback. Logic stays in the parent view's `seekToBlock` helper (the dumb cell keeps no logic).

**Tech Stack:** Swift, UIKit collection view (iOS), SwiftUI (macOS), GRDB timeline, Swift Testing.

## Root cause (verified)

The tap IS wired: iOS `didSelectItemAt` → `onTapBlock` → `seekToBlock` ([ReaderFeedCollectionView.swift:561-568](EchoCore/Views/ReaderFeedCollectionView.swift), [ReaderTab.swift:109-111](EchoCore/Views/ReaderTab.swift)); macOS `.onTapGesture` → `seekToBlock` ([MacReaderFeedView.swift:296-298, 76](Echo macOS/Views/MacReaderFeedView.swift)). The failures are in what it does:

1. **Wrong seek method.** `seekToBlock` calls the bare `model.playbackController.seek(to: time)` ([ReaderTab.swift:438-440](EchoCore/Views/ReaderTab.swift)), which is a thin pass-through to the audio engine ([PlaybackController.swift:274](EchoCore/Services/PlaybackController.swift)) — no progress/artwork refresh, no `isManualSeeking`, **no play/resume**. The canonical user seek is `PlayerModel.seek(toSeconds:)` → `PlaybackController.seek(toSeconds:)` ([PlaybackController.swift:753-767](EchoCore/Services/PlaybackController.swift), [PlayerModel.swift:1314](EchoCore/ViewModels/PlayerModel.swift)), which every other UI seek uses (chapter taps, scrubber, CarPlay, bookmarks). Even it only *resumes* if already playing — so the fix must also call `play()` to start from paused.
2. **Silent no-op for un-timed blocks.** Un-narrated/un-aligned blocks store `audio_start_time = -1` ([AlignmentService.swift:290](EchoCore/Services/AlignmentService.swift)); the `time >= 0` guard ([ReaderTab.swift:438](EchoCore/Views/ReaderTab.swift)) means tapping them does nothing, with zero feedback. On a freshly imported (not-yet-aligned) book, *every* tap silently dies — likely what Dan is hitting.
3. **No active-block set.** `seekToBlock` doesn't set `activeBlockID` (only `seekToBlockAndScroll` does, [ReaderTab.swift:443-450](EchoCore/Views/ReaderTab.swift)), so even a successful seek doesn't highlight/scroll to the tapped card → reinforces "nothing happened."

Resolvers exist and are shared across source types via the materialized `timeline_item` table: iOS `ReaderFeedViewModel.audioStartTime(for:audiobookID:)` ([ReaderFeedViewModel.swift:319-329](EchoCore/ViewModels/ReaderFeedViewModel.swift)); macOS `timelineCache` ([MacReaderFeedView.swift:161-197](Echo macOS/Views/MacReaderFeedView.swift)). Narrated books populate it in `NarrationService.swift:200-211`; aligned books in `AlignmentService`. **Latent multi-track bug:** `audio_start_time` is per-track but `seek(toSeconds:)` seeks within the *current* track — tapping a card in a different track seeks the wrong place (narrated + single-track books are unaffected).

## Decisions made while you slept (override freely)

- **Tap = seek AND play** (start from paused too) — matches the user's stated expectation.
- **Use `model.seek(toSeconds:)` + explicit play**, not the bare engine seek — consistent with every other seek in the app (refreshes progress/artwork/now-playing).
- **Set `activeBlockID` on tap** so the card highlights/scrolls into view (reuse `seekToBlockAndScroll`'s behavior).
- **No-time fallback = feedback, never a dead tap.** iOS: light haptic + scroll/pulse the card (infra exists: `pulseCell` [ReaderFeedCollectionView.swift:401], `forceScrollBlockID`). macOS: scroll/select (no haptics).
- **Keep logic in the parent `seekToBlock` helper** (not in the dumb `ParagraphCardCell`/macOS row) — matches the codebase's "logic out of views."
- **Multi-track cross-track seek is a follow-up**, not part of this fix. The common cases (narrated, single-track m4b) work with seek-method + play + active-block. Flag the multi-track gap.

## Open questions for Dan
1. Tap from paused → auto-start playback (chosen) vs seek-only-and-stay-paused?
2. No-time fallback: haptic-only, or also pulse/scroll? Should tapping an un-aligned card offer "align to now" instead of nothing?
3. Multi-track cross-track seek: in scope now or a separate follow-up? (Recommend follow-up.)
4. macOS feedback acceptable with minimal/no cue (no haptics)?

## Global Constraints
- Branch target **`nightly`**. Cross-platform behavior change → run `cross-platform-parity-reviewer`; land on both `ReaderTab.swift` (iOS) and `MacReaderFeedView.swift` (macOS).
- No read-along feed on watch/widget/CarPlay (CarPlay seeks chapters, not paragraphs) — no change there.
- Tap must not regress the iOS long-press context menu (alignment/color/bookmark) — distinct recognizers, verify.
- Tests via `make build-tests` + `make test-only FILTER=…`; use `DatabaseService(inMemory:)` for resolver tests. UI tests excluded — prefer pure logic.

## File Structure
- `EchoCore/Views/ReaderTab.swift:435-441` — **modify**: rewrite `seekToBlock` (full seek + play + active block + fallback).
- `Echo macOS/Views/MacReaderFeedView.swift:216-219` — **modify**: same.
- (New, recommended) a pure `CardTapDecision` helper + test.
- `EchoTests/` — resolver test (in-memory DB) + decision test.

---

### Task 1: Pure tap decision + resolver test

**Files:**
- Create (recommended): a small pure helper, e.g. `Shared/CardTapDecision.swift` returning `.seekAndPlay(seconds:)`, `.switchTrackThenSeek(track:seconds:)`, or `.noTime`.
- Test: `EchoTests/CardTapDecisionTests.swift`; extend a resolver test using `DatabaseService(inMemory:)`.

**Interfaces:**
- Consumes: a block's resolved `audio_start_time` (nil/negative = no time), and (for multi-track) the block's track vs the current track.
- Produces: a `CardTapDecision` the views act on.

- [ ] **Step 1: Failing tests** — decision returns `.seekAndPlay(t)` for a non-negative time on the current track; `.noTime` for nil/`-1`; `.switchTrackThenSeek` when the block's track ≠ current (multi-track guard).

```swift
@Test func tapWithTimeSeeksAndPlays() {
    #expect(CardTapDecision.make(time: 12.5, blockTrack: 0, currentTrack: 0) == .seekAndPlay(seconds: 12.5))
}
@Test func tapWithoutTimeIsNoTime() {
    #expect(CardTapDecision.make(time: nil, blockTrack: 0, currentTrack: 0) == .noTime)
    #expect(CardTapDecision.make(time: -1, blockTrack: 0, currentTrack: 0) == .noTime)
}
```

- [ ] **Step 2:** Run → fail (helper doesn't exist).
- [ ] **Step 3:** Implement `CardTapDecision.make(...)` (pure).
- [ ] **Step 4:** Run → pass.
- [ ] **Step 5: Resolver test** — with an in-memory DB, assert `audioStartTime(for:audiobookID:)` returns the stored time for an aligned/narrated block, nil/negative for an un-aligned block, and respects track-scope gating.
- [ ] **Step 6:** Run → pass.
- [ ] **Step 7: Commit:** `git commit -m "feat(read-along): pure card-tap decision + resolver tests"`

### Task 2: Wire iOS tap → seek + play + highlight + fallback

**Files:** Modify `EchoCore/Views/ReaderTab.swift:435-441`.

**Interfaces:**
- Consumes: `CardTapDecision`, `model.seek(toSeconds:)`, `model.play()`, `viewModel.activeBlockID`, `coordinator.pulseCell`/haptics.
- Produces: tap seeks + plays, highlights the card; no-time tap gives feedback.

- [ ] **Step 1:** Rewrite `seekToBlock` to use the decision. Illustrative:

```swift
private func seekToBlock(_ blockID: String) {
    guard let vm = viewModel else { return }
    let time = vm.audioStartTime(for: blockID, audiobookID: folderURL.absoluteString)
    switch CardTapDecision.make(time: time, blockTrack: vm.track(for: blockID), currentTrack: model.currentTrackIndex) {
    case .seekAndPlay(let s):
        model.seek(toSeconds: s)
        if !model.isPlaying { model.play() }
        viewModel?.activeBlockID = blockID
    case .switchTrackThenSeek(let track, let s):
        // follow-up: load `track` then seek; for now, fall through to seekAndPlay on current track or no-op safely
        _ = (track, s)
    case .noTime:
        Haptic.play(.light)
        viewModel?.activeBlockID = blockID   // scroll/pulse so the tap registers
    }
}
```

- [ ] **Step 2:** Confirm tap-to-seek does NOT trip the drag-disables-autoscroll path ([ReaderFeedCollectionView.swift:433-437](EchoCore/Views/ReaderFeedCollectionView.swift)) (a tap is `didSelectItemAt`, not a drag) and does NOT arm the long-press context menu ([ReaderFeedCollectionView.swift:570-579]).
- [ ] **Step 3:** On-device check (Dan): (a) tap a narrated card → jumps + starts playing + highlights; (b) tap while playing → continues from there; (c) tap an un-aligned card → haptic, scrolls, no dead tap; (d) long-press still opens the context menu.
- [ ] **Step 4: Commit:** `git commit -m "feat(read-along): tap a card to seek and play (iOS)"`

### Task 3: macOS parity

**Files:** Modify `Echo macOS/Views/MacReaderFeedView.swift:216-219`.

- [ ] **Step 1:** Rewrite `seekToBlock` to use the player's full seek + start playback + select/scroll the card, mirroring iOS via `CardTapDecision`. No-time → scroll/select (no haptics).
- [ ] **Step 2:** On-device check (Dan, macOS): tap seeks + plays; un-timed card scrolls without a dead tap.
- [ ] **Step 3: Commit:** `git commit -m "feat(read-along): tap a card to seek and play (macOS parity)"`

### Task 4 (follow-up, optional): multi-track cross-track seek
- Resolve a block's track (chapter→track) and route through the track-aware seek (mirroring `seekToChapter`/`seekToAggregatedChapter`, [PlaybackController.swift:558, 592](EchoCore/Services/PlaybackController.swift)) when the block's track ≠ current. Add a test: a block in track N≠current → `.switchTrackThenSeek`. Only needed for multi-track imported books.

---

## Self-review notes
- **Spec coverage:** "tapping doesn't start playback" → Task 2/3 (seek + play). Plus the silent-no-op feedback and active-block highlight that make the tap *feel* like it worked. Multi-track flagged (Task 4).
- **No placeholders:** all file:line concrete; both seek APIs and their behaviors verified.
- **Type consistency:** `seek(toSeconds:)`, `play()`, `audioStartTime(for:audiobookID:)`, `activeBlockID`, `CardTapDecision` consistent across tasks.
- **Risk:** low for the common path; the multi-track wrong-seek is pre-existing and explicitly deferred (guarded by the decision returning `.switchTrackThenSeek` rather than silently seeking wrong).
