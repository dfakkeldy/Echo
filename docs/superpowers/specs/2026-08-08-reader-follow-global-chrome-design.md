# Reliable Reader Follow and Global Chrome — Design

**Date:** 2026-08-08
**Status:** Approved (brainstorming); ready for implementation planning
**Scope:** iOS Reader, shared iOS player dock, and root navigation chrome. The
macOS and watchOS interfaces are unchanged.
**Branch lineage:** `feature/reader-follow-global-chrome` from `nightly`

## 1. Summary

Make word-level read-along reliably become live after a sidecar is finalized,
replace the Reader's ambiguous auto-scroll boolean with explicit follow and
explore states, and keep the spoken line magnetically centered only while the
user is following playback. Manual scrolling must detach the viewport until the
user taps a persistent **Return to current text** control.

In the same focused iOS interaction pass, make the folder control global across
the main navigation hierarchy without overlapping screen content, and give the
bottom-dock **Mark passage for later** action visible success or failure
feedback.

The audiobook-generation workflow is not part of this change. The reported
book's delivered EPUB and sidecar were byte-identical to the accepted render;
`echo-cli verify-sidecar` accepted all 164 sidecar anchors and their word
timings. Echo also reported that 164 of 168 imported blocks accepted those
timings. The four remaining blocks are not evidence of a narration failure:
sidecars cover narrated text, while the imported block total may also include
non-spoken content.

## 2. Goals

- A completed or late-arriving sidecar refreshes an already-visible Reader
  without requiring the user to leave and reopen the screen.
- Following playback keeps the active spoken line at the vertical center when
  content bounds allow it.
- A user-initiated scroll enters an explicit exploring state. Words,
  paragraphs, chapters, reloads, and queued scroll operations cannot move the
  viewport while exploring.
- A persistent, labelled return control is available while exploring. Only a
  successful return action resumes automatic following.
- The centre bottom-dock passage button communicates whether it saved anything.
- The open-folder button is visible across Library, Reader, Now Playing, and
  their pushed navigation destinations, with content reserving its height once.
- Existing accessibility, localization, Dynamic Type, Reduce Motion, and iOS 18
  deployment behavior remain intact.

## 3. Non-goals

- No audiobook-skill, narration-renderer, sidecar-format, or private book
  artifact changes.
- No macOS or watchOS UI redesign.
- No general Reader architecture rewrite or new persistence layer.
- No global header inside modal sheets such as Book Settings.
- No change to what a marked passage means or where it appears later; this work
  only makes the existing action's outcome visible.
- No user setting for word-level highlighting. Read-along remains data-driven.

## 4. Root cause and current-state evidence

### 4.1 Intermittent word-level activation

`DocumentImportFinalizer` applies sidecar words, posts
`.timelineItemsIngested`, and the post-load path advances
`PlaybackState.documentIngestionTrigger` after finalization. `ReaderTab`
currently reloads its `ReaderFeedViewModel` only when it receives the transient
notification. It does not observe the durable ingestion generation.

If Reader loads its `wordCache` before finalization and misses the notification,
paragraph highlighting remains live but active-word lookup has stale or empty
data. Leaving Reader and returning calls `prepareReader()` and `reload()` again,
which explains why word highlighting appeared immediately after the user opened
Book Settings and returned.

The durable generation is therefore the correctness signal. The notification
may remain as a low-latency hint, but it cannot be the only invalidation path.

### 4.2 Follow-mode mismatch

Reader uses `autoScrollEnabled: Bool`. User dragging writes `false`, but
programmatic block scrolls are scheduled in unstructured main-actor tasks and
chapter playback can rebuild the displayed sections. The boolean does not
express the required contract or provide a durable cancellation boundary.
`ReaderWordFollowScroll` also uses a wide visible band, moving only when the word
approaches an edge rather than keeping the spoken line centered.

### 4.3 Chrome and passage feedback

`UnifiedTopHeader` conditionally renders the folder button only on Library and
the root hides the entire header with Reader chrome. Header clearance is
duplicated independently inside Reader, Now Playing, and the Library shelf. In
Library the clearance sits below `LibraryModePicker`, so the overlaid folder and
timer controls collide with Books/Inbox/Anthologies.

The centre utility button calls `markPassageAtCurrentTime()`, whose guard and
database-failure paths return silently. A haptic is played regardless of whether
a passage was saved, so the button has no honest visible result.

## 5. Reader follow architecture

### 5.1 State ownership

Add a small `ReaderFollowState` value with two cases:

- `following`: playback may move the Reader viewport and auto-expand the playing
  chapter.
- `exploring`: playback continues to update active block and active word state,
  but it may not move the viewport or change the open chapter.

`RootTabView` owns the state and passes a binding to `ReaderTab`, which passes it
to `ReaderFeedCollectionView`. Root ownership preserves exploration when the
user briefly changes primary tabs. Loading a different book resets the state to
`following`; ordinary playback, seeking, timing reloads, and tab changes do not.

### 5.2 State transitions

- Reader starts in `following` for a newly loaded book.
- `scrollViewWillBeginDragging` changes the state to `exploring` and cancels or
  invalidates all queued and in-flight programmatic scrolling.
- Active word and block calculations continue while exploring so returning can
  target the latest playback position.
- Playback crossing a paragraph or chapter does not restore following.
- Tapping or seeking within Reader does not restore following.
- Only a successful **Return to current text** action changes `exploring` back
  to `following`.

Every asynchronous/programmatic scroll must re-check follow state immediately
before changing content offset. A scroll scheduled while following becomes a
no-op if the user detaches before it executes.

### 5.3 Magnetic centering

While following with word timing, the collection view converts the active word
glyph rectangle into collection coordinates and targets the vertical center of
the usable viewport. Words on the same rendered line produce the same target,
so the page moves line by line rather than horizontally or on every word tick.
Targets are clamped at the start and end of content and suppressed within a
small sub-point tolerance.

If the active block has no current word, Echo centers the active paragraph as a
fallback. Block centering and word centering must not compete in the same update:
word centering wins whenever an active word rectangle is available.

Chapter auto-expansion is conditional on both playback and `following`. The
currently open chapter remains stable while exploring.

## 6. Reliable timing refresh

Expose the existing document-ingestion generation to Reader and include it in a
durable reload trigger. When the generation changes, Reader:

1. coalesces duplicate notification/generation events;
2. reloads timeline rows and word rows into `ReaderFeedViewModel`;
3. resolves the current active block and word at the live playback time; and
4. refreshes visible highlighting.

The existing `.timelineItemsIngested` subscription remains as a fast path for
incremental narration updates. The generation change guarantees correctness if
that notification arrives before Reader subscribes.

A refresh must preserve `ReaderFollowState`. While exploring, it must also
preserve the visible content anchor and offset; applying a data-source snapshot
cannot snap to the playback location. While following, the newly resolved word
may immediately become the magnetic target.

## 7. Return-to-current control

While `ReaderFollowState == .exploring`, Reader displays a labelled
**Return to current text** pill centered directly above the root-owned bottom
dock. It is independent of the auto-hiding local chapter header and has a
minimum 44-point target.

On tap, Reader resolves the latest active block and word, expands the containing
chapter if needed, and force-scrolls to the active word line (or paragraph
fallback). The state changes to `following` and the pill disappears only after a
target resolves. If timing is temporarily unavailable, the pill remains and
briefly reports **Finding current text…**; a later ingestion refresh makes the
next return attempt succeed.

Remove the existing local-header jump-to-current affordance. The conditional
pill is the one return action, so two controls cannot disagree about follow
state.

## 8. Mark-passage result feedback

Change the internal passage-capture operation to return an explicit result:

- `saved`
- `unavailable` when there is no loaded playable book or finite position
- `failed` when persistence throws

Existing Watch, CarPlay, and long-press call sites may deliberately ignore the
result. The bottom-dock button consumes it:

- `saved`: success haptic, temporary checkmark, a short **Passage marked** status
  capsule above the dock, and the same accessibility announcement;
- `unavailable` or `failed`: error haptic, temporary exclamation icon, and a
  short **Couldn't mark passage** status capsule plus announcement;
- no playable book: the button remains disabled.

If the Reader return pill is also visible, the transient passage status stacks
above it instead of covering it.

Database errors remain logged without exposing private book text.

## 9. Global header and layout

`UnifiedTopHeader` always renders the folder button alongside the existing
sleep-timer pill. Reader may still hide its local chapter/navigation header, but
it no longer hides the root global row.

Reserve `UnifiedTopHeader.rowOneHeight` once at the root content boundary so the
three primary `NavigationStack`s and their pushed destinations inherit the same
top clearance. Remove the per-screen global-row reservations from Reader, Now
Playing, and `LibraryShelfGrid`. Reader's own self-measuring header remains as a
separate inset below the global row.

This places Library's global clearance above `LibraryModePicker`, eliminating
the current overlap for Books, Inbox, and Anthologies. Modal sheets cover the
root hierarchy normally and do not reproduce the folder control.

## 10. Accessibility and motion

- Folder, return, and passage controls retain at least 44-by-44-point hit areas.
- Folder keeps the label **Open book or folder**.
- Return uses a visible text label plus an accessibility hint explaining that it
  resumes following playback.
- Passage feedback is exposed through VoiceOver as well as visual state.
- Dynamic Type may enlarge the return pill without clipping or covering Reader
  text.
- Reduce Motion replaces animated magnetic/return scrolling and icon morphing
  with immediate state changes; behavior is otherwise identical.
- User-visible strings are localized through the repository's existing string
  catalog workflow.

## 11. Testing and acceptance

### 11.1 Focused automated tests

- A Reader loaded with an empty/stale word cache reloads when the durable
  ingestion generation changes and resolves the current word without screen
  recreation.
- Notification and generation changes coalesce rather than causing duplicate
  full-book reloads.
- User drag transitions `following -> exploring`.
- Word, paragraph, chapter, seek, reload, and primary-tab changes leave
  `exploring` unchanged.
- A successful return transitions `exploring -> following`; an unresolved return
  does not.
- A queued scroll becomes a no-op after detachment.
- Magnetic policy centers the active line, avoids repeat movement on one line,
  and clamps at both content edges.
- Word centering wins over paragraph fallback when both are available.
- Mark passage returns `saved`, `unavailable`, and `failed` on their respective
  paths, and the UI feedback mapping is correct.
- Global-header policy renders the folder control for every primary tab and does
  not hide it with Reader's local chrome.

### 11.2 Visual and interaction acceptance

- Open a sidecar-backed book directly into Reader: word highlighting becomes
  live without leaving the screen.
- While playing, manually scroll several paragraphs away and cross at least one
  paragraph and one chapter boundary: the viewport stays put.
- Tap **Return to current text**: the current spoken line centers and remains
  magnetically centered as narration advances.
- Verify the folder control on Library, Reader, Now Playing, and one pushed
  destination; verify it is absent from Book Settings.
- Verify Books/Inbox/Anthologies are unobscured on compact and large Dynamic Type
  sizes.
- Mark a passage and confirm visual, haptic, VoiceOver, and inbox behavior.
- Repeat the Reader interactions with Reduce Motion enabled.

Run focused tests first, then the repository's full `make test` gate. Every
Apple build/test command must use the repository-mandated Xcode build-slot
wrapper. Simulator or physical-device acceptance is reported separately from
unit-test and build status.

## 12. Risks and containment

- **Competing scroll sources:** block follow, word follow, forced return, chapter
  expansion, and snapshot application can fight. A single follow state and a
  re-check at every offset mutation provide the cancellation boundary.
- **Reload churn:** both notification and generation can report one ingestion.
  Reuse the existing coalescing token/quiet window rather than adding another
  reload pipeline.
- **Offset movement during snapshot application:** preserve a visible item anchor
  and relative offset while exploring if the diffable data source changes.
- **Header double insets:** root ownership requires deleting all three existing
  per-screen global-row reservations in the same change.
- **Bottom-dock crowding:** the return pill is conditional and sits above the
  dock, not inside its five-slot control row.

## 13. Implementation boundaries

The implementation should stay within the existing concrete SwiftUI/UIKit and
Observation architecture. No third-party dependency, protocol layer, schema
migration, or audiobook-workflow change is needed. Small pure policies or result
enums are appropriate where they make state transitions, centering, and feedback
directly testable.
