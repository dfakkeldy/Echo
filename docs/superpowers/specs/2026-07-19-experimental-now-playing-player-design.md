# Experimental Now Playing Player — Design

**Date:** 2026-07-19
**Status:** Approved (brainstorming); ready for implementation planning
**Scope:** iOS only. macOS and watchOS players are untouched by this work.
**Branch lineage:** `claude/now-playing-redesign-3e1b61` (off `nightly`)

## 1. Summary

Add an opt-in, experimental Now Playing player, selectable via a Settings toggle, that
replaces the current dock/toolbar chrome with a **full-bleed cover** and **individual round
Liquid Glass buttons** the user can configure, drag between snap zones, fine-tune, and lock.
Independently, add a **shared image component** giving tap-to-fullscreen and long-press-to-save
to cover art (both players) and inline reader/visual-listening images.

The current player remains the default and is always one toggle away. Everything new is gated
behind the flag, making the experiment fully reversible.

## 2. Goals

- A settings toggle switches the iOS Now Playing tab between the current player and an
  experimental one, with no change to the current player when the flag is off.
- Experimental layout: cover art bleeds off the top and sides, then blends into the existing
  cover-derived theme wash where controls sit.
- Transport/utility controls become individual round Liquid Glass buttons. The user chooses
  **which** controls appear (curated default set), places each in one of a fixed set of **snap
  zones**, and can **nudge** within a zone. A `⋯` overflow button always exists for the rest.
- A **lock/edit** mode: locked = clean playback; unlocked (via long-press) = rearrange, add/remove.
- Layout choices persist across launches.
- One reusable `ZoomableArtwork` component: tap → fullscreen zoomable viewer; long-press → save
  to Photos with a correct add-only permission flow. Applied everywhere art appears, replacing the
  current permission-less reader save path.

## 3. Non-goals (YAGNI)

- No macOS or watchOS equivalent in this work. (The new `SettingsManager` key compiles into all
  targets but is phone-only in effect; macOS would need its own `Mac*` wiring later if desired.)
- No new *kinds* of controls — we reuse the existing `WatchAction` action model that already drives
  the configurable 5-slot transport.
- No free-form (arbitrary x/y) button placement — rejected in favor of snap zones + offset.
- No cropping the cover to fill (edge-to-edge crop treatment was rejected).
- No redesign of the current player, the Reader dock, or the top header beyond what dock-suppression
  requires.

## 4. Key decisions (validated in brainstorming)

1. **Gated experiment.** New layout lives behind `experimentalNowPlayingLayout` (default off).
2. **Configurable controls.** User picks which controls are their own buttons; rest go to `⋯`.
3. **Cover-to-theme blend.** Cover aspect-fills the top, bleeds off top+sides, dissolves into the
   existing `CoverThemeBuilder`/`AdaptiveBackground` wash.
4. **Snap zones + intra-zone nudge + lock.** Buttons snap to a fixed zone set; each has a bounded
   offset; long-press unlocks an edit mode; locked is the default/normal state.
5. **Image gestures everywhere.** Shared `ZoomableArtwork`: tap-fullscreen + long-press-save with a
   real permission flow; replaces `UIImageWriteToSavedPhotosAlbum` usage in the reader.

## 5. Architecture

### 5.1 Current-state anchors (what we build against)

- Player content: `EchoCore/Views/NowPlayingTab.swift` (`compactPlaybackLayout`, `artworkView`,
  `visualListeningOrArtworkView`, `playbackDetailsAndScrubber`).
- Root host: `EchoCore/Views/RootTabView.swift` owns the shared `UnifiedBottomDock` and the sheets.
- Transport/utility chrome: `UnifiedBottomDock.swift`, `TransportControlsView.swift` (5 configurable
  slots driven by `settings.phonePage`), `BottomToolbarView.swift`, `PlayerMoreMenu.swift`.
- Theme: `CoverThemeBuilder.swift` → `AdaptiveBackground.swift`; `PlayerModel.coverTheme`,
  `resolvedThemeTint`.
- Settings: `EchoCore/Services/SettingsManager.swift` (`@MainActor @Observable`, UserDefaults +
  app-group). Add-a-bool pattern mirrors `truncateChapterNamesEnabled`. Precedent for a layout
  style: `playerLayoutStyle` ("default"/"compact").
- Action model: `WatchAction` (already the vocabulary for configurable transport slots).
- Existing (to be replaced) save path: `ReaderTab.swift` `saveImageToCameraRoll(block:)` →
  `UIImageWriteToSavedPhotosAlbum` (no permission flow), invoked from `ReaderTab+Alignment.swift`.
- No Liquid Glass anywhere yet; chrome fakes it with `.ultraThinMaterial`.

### 5.2 New components

- `ExperimentalNowPlayingView` (new, EchoCore/Views) — the alternate upper+controls layout, rendered
  by `NowPlayingTab` when the flag is on.
- `FullBleedCoverBackground` (new) — cover aspect-fill top + gradient blend into the theme wash.
- `GlassControlButton` (new) — a single round Liquid Glass button wrapping a `WatchAction`, with an
  iOS 26 `.glassEffect` path and an `.ultraThinMaterial` fallback for < iOS 26.
- `ExperimentalControlLayer` (new) — hosts the configured buttons, resolves zone+offset → position,
  and owns the lock/edit interaction.
- `PlayerSnapZone` (new enum) — the fixed anchor set (e.g. `bottomLeading`, `bottomCenter`,
  `bottomTrailing`, `midLeadingRail`, `midTrailingRail`, `upperLeading`, `upperTrailing`).
  Exact set finalized in the plan; the mock used ~7.
- `ExperimentalPlayerButton` (new Codable) — `{ action: WatchAction, zone: PlayerSnapZone,
  offset: normalized CGSize }`. `ExperimentalPlayerLayout` = ordered `[ExperimentalPlayerButton]`
  plus schema version, persisted as JSON in `SettingsManager`.
- `ZoomableArtwork` (new) — reusable view/modifier: tap → `fullScreenCover` zoomable viewer;
  long-press → save-to-Photos via an injected `PhotoSaving` seam.
- `PhotoLibrarySaver` (new) — concrete add-only saver using `PHPhotoLibrary` +
  `PHAssetCreationRequest`; injected as a closure/concrete type for testability (per DI convention —
  no protocol until a second impl/test double exists; here the test double is the seam).

### 5.3 Data flow

- `SettingsManager.experimentalNowPlayingLayout` → `NowPlayingTab` branch → `ExperimentalNowPlayingView`.
- `RootTabView` reads the same flag + `selectedTab` and **suppresses `UnifiedBottomDock` only when
  the experimental Now Playing tab is active**; Reader and other tabs keep the normal dock.
- `ExperimentalControlLayer` reads/writes `SettingsManager.experimentalPlayerButtonLayout`
  (JSON). Button taps dispatch existing `WatchAction` handling on `PlayerModel` (same code paths as
  `TransportControlsView.buttonForAction`). `⋯` opens the existing `PlayerMoreMenu` closures.
- Colors/tint come from `PlayerModel.coverTheme` / `resolvedThemeTint` (unchanged).

## 6. Persistence & settings

New `SettingsManager` members (phone-only via `defaults`, NOT `appGroupSet`, following the
`truncateChapterNamesEnabled` steps: `Defaults`, `Keys`, stored property with `didSet`, `init`
read, registration dict):

- `experimentalNowPlayingLayout: Bool` — default `false`.
- `experimentalPlayerButtonLayout: String` (JSON) — default = encoded curated set. Decode failures
  fall back to the default set (never crash, never silently blank the controls).

Lock state is **not** persisted — the player always opens locked; edit mode is transient. A
"Reset layout" action in settings restores the default set.

## 7. Liquid Glass & platform gating

- Deployment target is iOS 18; `.glassEffect` is iOS 26+. `GlassControlButton` MUST gate with
  `if #available(iOS 26, *)` and provide the `.ultraThinMaterial` + stroke fallback used elsewhere,
  so the experiment is usable on iOS 18–25 too.
- All new UI is compiled/used only by the iOS target (EchoCore). macOS `Mac*` player and watch
  player are unchanged. Confirm existing parity tests (`MacNowPlayingParityTests`, etc.) still pass;
  add a note if a new shared key trips a settings-extraction/parity assertion.

## 8. Image gestures detail

- **Tap:** present a `fullScreenCover` hosting a zoomable image (magnification + pan gestures,
  swipe/tap-to-dismiss), chrome hidden, dark background. Works on iOS 18+ (custom gesture stack; do
  not rely on iOS-26-only zoom transitions).
- **Long-press:** request `PHPhotoLibrary.requestAuthorization(for: .addOnly)`; on authorized/limited,
  save via `performChanges { PHAssetCreationRequest.creationRequestForAsset(from:) }`; success →
  haptic + brief confirmation; denied → non-blocking message pointing to Settings. Requires
  `NSPhotoLibraryAddUsageDescription` in the iOS app Info.plist (absence = hard crash on first save).
- Applied to: cover art in the current player, cover art in the experimental player, and inline
  reader/visual-listening images — replacing `saveImageToCameraRoll(block:)`'s permission-less write.

## 9. Testing

- Layout codec: encode/decode round-trip; unknown/failed JSON → default set; schema-version handling.
- Zone resolver: `(zone, offset, containerSize, buttonSize) → CGPoint` stays on-screen and honors
  offset bounds. Pure function, unit-tested (no view).
- Settings: new keys register/read/write correctly; default-off; reset restores default set.
- Photo save seam: injected `PhotoSaving` double verifies authorized-save, denied-path, and
  add-only request are exercised without touching the real library.
- Parity: macOS/watch parity suites unaffected.
- Follow project test conventions (`make build-tests` once, `make test-only FILTER=...`).

## 10. Task decomposition (one implementation prompt each)

0. **Foundation** — `experimentalNowPlayingLayout` flag + Settings toggle + `ExperimentalNowPlayingView`
   shell (metadata + scrubber reused, empty control area) + `RootTabView` dock suppression. Ships an
   empty-but-safe experience behind the flag.
1. **Full-bleed blend background** — `FullBleedCoverBackground` (cover aspect-fill + gradient into
   theme wash), wired into `ExperimentalNowPlayingView`.
2. **Configurable glass buttons + snap zones + persistence** — `GlassControlButton`,
   `PlayerSnapZone`, `ExperimentalPlayerButton/Layout` codec, `ExperimentalControlLayer` (locked
   rendering + tap dispatch + `⋯` overflow), settings persistence + reset. (Depends on 0.)
3. **Lock/edit mode** — long-press to unlock, zone highlighting, drag-to-zone + intra-zone nudge,
   add/remove (`⊕`), done/lock. (Depends on 2.)
4. **`ZoomableArtwork` + tap-fullscreen** — reusable component + fullscreen zoom viewer, applied to
   cover art (both players) and reader/visual-listening images. (Independent of the layout.)
5. **Long-press save-to-Photos + permission** — `PhotoLibrarySaver`, add-only permission flow,
   Info.plist usage string, replace reader `UIImageWriteToSavedPhotosAlbum`. (Uses task 4's
   component; independent of the layout.)

Tasks 4–5 are independent of the layout and could ship first as app-wide wins. Task 0 unblocks 1–3.

## 11. Risks & open items

- **Info.plist crash risk:** shipping task 5's save without `NSPhotoLibraryAddUsageDescription`
  crashes on first long-press — the plist change is part of the task, not optional.
- **Liquid Glass availability:** must not regress iOS 18–25; fallback required.
- **Dock suppression correctness:** verify no layout jump / safe-area regression when the shared dock
  is hidden only for the experimental Now Playing tab (the dock is bottom-anchored in `RootTabView`).
- **Visual-listening mode:** the experimental layout should still show scene imagery in
  visual-listening; confirm `FullBleedCoverBackground` degrades sensibly when there is scene art vs a
  static cover. Finalize in task 1's plan.
- **Zone set:** the exact zone enum (count/positions) is provisional (~7 in the mock); lock it in the
  task-2/3 plan.
- **Docs:** on completion, update `ARCHITECTURE.md` (new player + settings key) and `CHANGELOG.md`
  via the `doc-sync` skill.
