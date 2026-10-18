# Compact Reader Top Chrome — Design

**Date:** 2026-08-16
**Status:** Approved (brainstorming); ready for implementation planning
**Scope:** iOS standalone EPUB Reader and its existing bottom overflow menu.
PDF, transcript, Library, Now Playing, macOS, and watchOS surfaces are unchanged.
**Branch lineage:** `feature/reader-compact-top-chrome-design` from `nightly`

## 1. Summary

Remove the root-owned folder and sleep-timer row while the standalone EPUB
Reader is visible. This gives the Reader's search and utility controls the top
safe-area position, reclaims the 64-point global row, and
eliminates the current collision between the folder chip and the search field.

Preserve both displaced actions in the Reader's existing bottom **More** menu.
An active sleep timer remains visible through a small moon badge on the More
control without adding another row or reducing the search field's width.

## 2. Current problem

`RootTabView` overlays `UnifiedTopHeader`, which contains the folder chip and
`SleepTimerPill`, above the primary navigation stacks. `ReaderTab` independently
insets its search, table-of-contents, settings, and sessions row at the top.

The root-level `UnifiedTopHeader.rowOneHeight` reservation does not reliably
propagate through the Reader's `NavigationStack`. As a result, the global folder
chip and the Reader search row can occupy the same vertical band. Reserving the
global row again inside Reader would prevent the collision, but it would also
permanently spend roughly 64 points on controls that are not central to reading.

## 3. Goals

- The folder chip and sleep-timer pill do not appear above the standalone EPUB
  Reader.
- The Reader search and utility row begins directly below the system safe area.
- Opening another book or folder remains reachable from the Reader without
  switching screens first.
- The full sleep-timer menu remains reachable from the Reader.
- An armed sleep timer has a visible, accessible state on the Reader without a
  dedicated top row.
- Other app surfaces retain their current global header and spacing.
- Tab changes and navigation transitions do not produce overlapping or doubled
  top clearance.

## 4. Non-goals

- No redesign of the Reader's search, filter, chapter, or bottom-dock controls.
- No change to PDF page or reflow presentation, standalone transcripts,
  Library, Now Playing, modal sheets, macOS, or watchOS.
- No change to sleep-timer behavior, presets, countdown logic, or persistence.
- No change to folder import or book-loading behavior.
- No general rewrite of global chrome or navigation architecture.
- No new user preference for showing or hiding the Reader header.

## 5. Considered approaches

### 5.1 Hide the global row and relocate its actions — selected

Suppress `UnifiedTopHeader` and its height reservation only for the standalone
EPUB Reader. Add the folder and sleep-timer actions to the existing bottom More
menu.

This recovers the full row height, retains both capabilities, and does not add
horizontal pressure to the search row.

### 5.2 Auto-hide the global row while scrolling

This would preserve the current controls until scrolling begins, but the Reader
would still either reserve their height or shift vertically as they appear and
disappear. It also introduces another scroll-driven state machine alongside the
Reader's existing local-header behavior.

### 5.3 Merge the actions into the Reader utility row

This would avoid a second row but would further compress the search field beside
the existing table-of-contents, typography, and sessions controls. It recreates
the compact-width pressure that made the collision especially disruptive.

## 6. Surface selection and ownership

`RootTabView` remains the owner of global-header visibility and clearance. Add a
small, pure layout resolver that determines whether the current root surface is
the standalone EPUB Reader. The compact state requires all of the following:

- the selected primary tab is Read;
- the Read navigation path is at its root;
- reflowable EPUB content is present; and
- the current root is not a PDF or transcript surface.

When the resolver returns the compact Reader state, `RootTabView` omits both
`UnifiedTopHeader` and the associated `rowOneHeight` reservation. When it returns
any other state, existing global-header behavior is unchanged.

The condition belongs at the root rather than inside `ReaderTab`, because the
root owns both the overlaid header and the navigation-stack clearance. Including
the Read path state ensures that a destination pushed from Reader receives the
normal global header instead of inheriting the Reader-only suppression.

## 7. Reader overflow actions

Extend the existing `PlayerMoreMenu` inputs with Reader-only optional actions:

- **Open Book or Folder…** invokes the root-owned folder picker.
- **Sleep Timer** opens the same presets and cancellation choices currently
  provided by `SleepTimerPill`.

The optional actions are supplied only while the compact standalone Reader is
active, so other surfaces do not gain duplicate menu entries. Extract the
sleep-timer choices into one focused menu-content component used by both
`SleepTimerPill` and the Reader overflow menu. It reads and mutates the existing
`PlayerModel` timer state; it does not duplicate timer state or business logic.

Place both entries in the playback/current-book portion of More, before the
app-level Settings and Help actions. The folder entry uses the existing picker
and loading path owned by `RootTabView`.

## 8. Active timer indication

When the compact Reader is visible and `sleepTimerMode.isActive` is true, add a
small moon badge to the existing More icon. The badge:

- does not change the control's 44-point footprint;
- uses the current cover-derived accent treatment;
- does not display a live numeric countdown; and
- updates the control's accessibility value to describe the active timer,
  including end-of-chapter mode where applicable.

When a timed timer is active, the Sleep Timer submenu includes a disabled status
row with its remaining time. End-of-chapter mode receives an equivalent active
status row. `SleepTimerPill` continues to show its live countdown on the other
surfaces. Avoiding per-second text in the dock prevents distracting Reader
updates and layout churn.

## 9. Transitions and state

Switching into the standalone Reader removes the global row and its reservation
as one layout state. Switching away restores them together. Use the app's
existing short chrome transition and honor Reduce Motion; the header must never
animate independently from its reserved space.

Hiding the header does not modify folder selection, playback, timer, Reader
follow state, search text, or Reader local-header visibility. If a timer is
already armed, entering Reader immediately shows the More-control badge.

## 10. Accessibility and localization

- Preserve the existing **Open book or folder** and **Sleep Timer** meanings in
  the relocated menu actions.
- Give the badged More control an accessibility value that reports the active
  timer state without relying on the badge alone.
- Keep all menu titles localizable.
- Maintain 44-point minimum hit targets and current Dynamic Type behavior.
- Verify the layout with Reduce Motion enabled.

## 11. Verification

Add narrow tests for the pure layout resolver:

- standalone EPUB Reader root hides the global row;
- Library and Now Playing retain it;
- PDF and transcript Read roots retain it;
- a pushed Read destination retains it.

Add or update menu tests to confirm that Reader-only folder and sleep-timer
inputs compile and that absent inputs do not create actions on other surfaces.
Cover the sleep-timer badge's inactive, timed, and end-of-chapter accessibility
states with pure-state tests.

Perform an iPhone compact-width smoke check that confirms:

- the folder chip no longer collides with the search field;
- the search row begins beneath the status-bar safe area;
- no blank 64-point band remains;
- both relocated actions work from More;
- an active timer is visibly and accessibly indicated; and
- switching among Reader, Library, and Now Playing restores the correct header
  without jumps, overlap, or doubled clearance.

## 12. Acceptance criteria

- On the standalone EPUB Reader, the global folder/sleep row is absent and no
  height is reserved for it.
- The Reader's local top controls are fully visible and non-overlapping at
  compact iPhone widths.
- Folder selection and every existing sleep-timer choice remain available from
  the Reader's bottom More menu.
- An active timer is indicated on the More control without adding vertical
  chrome.
- All excluded surfaces preserve their current global header.
- Relevant automated tests pass, and the compact-width smoke check shows no
  regression in safe-area, transition, localization, or accessibility behavior.
