# Narration Status Visibility Design

**Status:** Approved for implementation planning

**Date:** 2026-08-10

**Owner:** Echo iOS narration playback

## Outcome

Echo makes on-device narration observable from the moment a narration request is
accepted until playback finishes, fails, or is cancelled. A persistent iOS status
card reports model delivery, model loading, rendering, playback, and render-ahead
buffer state without conflating concurrent work. The card expands into a
timestamped event history, and the same privacy-safe lifecycle events are emitted
through unified logging for developer diagnosis.

The user can distinguish at least these cases without guessing:

- the narration model is downloading or loading;
- the first playable segment is rendering;
- audio is playing while later content renders;
- rendering is intentionally held by look-ahead backpressure;
- playback is paused by the user or system;
- playback has exhausted the rendered queue and is waiting for the next segment;
- the next segment became ready and playback resumed;
- all rendering completed while playback continues;
- playback completed naturally;
- preparation, rendering, or playback failed or was cancelled.

## Verified Current Gaps

The current implementation already carries model fractions and per-block render
fractions, but the signals are incomplete and inconsistently presented:

- `NarrationStatusView` exists only in the standard `NowPlayingTab` layout.
  Enabling `SettingsManager.experimentalNowPlayingLayout` replaces that layout
  with `ExperimentalNowPlayingView`, which does not mount the card at all.
- The card renders only for `NarrationState.isRunning` or `.failed`. It disappears
  after render completion and has no playing, paused, waiting, or playback-complete
  presentation.
- A queue underrun calls `pause()` and sets
  `PlaybackState.awaitingNarrationChapter`, but no user-visible status or log event
  explains why playback stopped.
- Preparation begins before the progress-reporting `TTSEngine.prepare` call.
  Planning, resource loading, and the non-reporting Now Playing prewarm can
  therefore run while `NarrationState` remains idle and the card remains absent.
- Model preparation updates the in-app state but not the lock-screen subtitle.
- Rendering completion and playback completion are not represented separately.
- `NarrationState.debugLog` is an unstructured string array and is not surfaced by
  the iOS card.

## Scope

### Included

- iOS standard and experimental Now Playing layouts;
- compact and expanded narration status-card presentations;
- concise lock-screen narration status;
- structured in-memory session events and unified logging;
- exact model byte progress for the pinned ONNX model;
- render progress at chapter, segment, and speakable-block granularity;
- playback, queue-wait, buffer, auto-resume, completion, cancellation, and failure
  transitions;
- localization and accessibility for all new user-visible content;
- focused unit and presentation tests plus an iOS Simulator smoke test.

### Not included

- changing narration audio quality, render-ahead depth, or synthesis policy;
- downloading voice packs. Echo's English Kokoro voice packs are bundled resources,
  so the UI will report loading or selecting a voice rather than invent a voice
  download;
- persistent diagnostic history across books or app launches;
- logging book text, book titles, private paths, or pronunciation content;
- automatic cancellation or retry merely because synthesis is slow;
- a new third-party dependency.

## State Model

Narration preparation/rendering and playback are concurrent dimensions. A single
exclusive phase cannot truthfully represent "playing chapter 2 while rendering
chapter 4," so `NarrationState` will own one observable session snapshot with
separate facts.

### Preparation and rendering

The render dimension represents:

- idle;
- planning the book and resolving voices;
- checking the model cache;
- downloading the model with received and total bytes;
- validating the downloaded model;
- loading the ONNX session;
- rendering a chapter/segment with completed and total speakable blocks, voice,
  start time, and latest-progress time;
- held by render-ahead backpressure;
- all planned content rendered;
- cancelled;
- failed.

### Playback

The playback dimension represents:

- not started;
- loading the first rendered track;
- playing a chapter/segment;
- paused by the user or system;
- waiting for a specific next segment because the rendered queue is empty;
- resuming after that segment becomes ready;
- stopped;
- naturally completed;
- failed.

The existing queue-gap path records `waitingForRender` before/around its generic
pause operation, so it cannot be reported as a user pause. Ordinary pause paths
record `pausedByUserOrSystem` and never claim the render buffer ran dry.

### Buffer

The buffer dimension records:

- total planned segments;
- rendered and queued segments;
- current playback index;
- count ready ahead of the active segment;
- next segment being rendered, if any.

These are counts of durable playable files, not estimates. A segment enters the
ready count only after audio finalization and insertion into the track queue.

### Compatibility

`NarrationState.isRunning` remains a derived compatibility property for existing
command gating. It answers whether preparation or rendering work is active, not
whether audio happens to be playing. `Phase` remains only as a computed
compatibility projection of the new render and playback dimensions; stored phase
mutation and the generic `update(phase:progress:statusMessage:)` entry point are
removed so they cannot become a second source of truth.

## Structured Events and Unified Logging

`NarrationState` owns a bounded event history for the active narration session.
Each `NarrationEvent` contains:

- timestamp;
- category (`preparation`, `model`, `voice`, `render`, `buffer`, `playback`, or
  `error`);
- severity (`info`, `notice`, `warning`, or `error`);
- a localized in-app message;
- a privacy-safe developer message and structured numeric metadata where useful.

The history retains the latest 200 events. Starting a new narration session or
switching books clears the prior session. Completion, pause, or failure does not
clear it, so the user can expand the card after something stops.

One state-transition method updates the snapshot, appends the event, and emits the
matching `Logger` entry. High-frequency samples update live state without flooding
history:

- download bytes update the progress bar continuously but append milestones at
  start, every five percentage points, validation, and completion;
- render history records render-unit start, each completed speakable block, file
  finalization, and queue insertion;
- playback history records commands and actual queue transitions rather than
  periodic time ticks.

Unified logs expose chapter/segment indexes, voice IDs, counts, byte totals,
durations, elapsed time, and stable error types. Book content, title, author,
source text, and local file paths are omitted. User-facing error descriptions may
appear in the private in-app history; unified logs keep free-form descriptions
private and publish only safe error classification and numeric codes.

## Model and Voice Reporting

`NarrationPrepareProgress.downloadingModels` is enriched from a fraction to exact
received and expected byte counts. The current pinned model is 163,234,740 bytes,
so the card can show both percentage and human-readable bytes. Cached models emit
an explicit cache-hit event before session loading rather than jumping silently to
ready.

The existing `compilingModels` naming is corrected for the ONNX engine. Echo does
not compile the model on device; it creates an ONNX session. Status therefore says
"Loading narration model" and records the measured load duration.

Voice packs remain bundled. Plan resolution records the selected default voice and
the number of overrides. When rendering changes voices, the live render status and
events identify the display name in-app and stable voice ID in developer logs.

## Status Card

`NarrationStatusView` becomes a persistent session card and is mounted in both iOS
Now Playing layouts. It is hidden before narration has ever started for the current
book, appears immediately when a request is accepted, and remains visible through
pause, all-rendered, natural completion, cancellation, or failure until the book is
switched or a new narration session replaces it.

### Collapsed presentation

The compact card contains:

- a state-specific symbol, spinner, or success/failure indicator;
- one primary playback/preparation line;
- one secondary render/buffer line when applicable;
- determinate progress for model download and per-unit rendering;
- an explicit Details disclosure control.

Representative summaries include:

- `Downloading narration model · 82% · 134 of 163 MB`
- `Loading narration model · 1.2s elapsed`
- `Rendering chapter 1 · block 8 of 19 · Ava`
- `Playing chapter 2 · rendering chapter 4, 63% · 1 ready ahead`
- `Waiting for chapter 3 · rendering 71%`
- `Paused · 2 chapters ready`
- `Playing chapter 4 · all narration rendered`
- `Narration failed · Model download failed`

When a render block has produced no new milestone for at least 30 seconds, the
live secondary line reports elapsed inactivity, for example
`Still synthesizing block 8 · no update for 34s`. This is diagnostic wording, not
an automatic failure. Echo does not cancel or retry solely because the threshold
was crossed.

### Expanded presentation

The disclosure expands an inline, reverse-chronological event list with timestamp,
category symbol, and message. It has a bounded height and scrolls independently so
it cannot push transport controls off screen. Expanding and collapsing does not
change narration behavior or clear events.

The card supports Dynamic Type, sufficient contrast, reduced-motion behavior,
VoiceOver labels for state/progress/buffer counts, and an explicit accessibility
expanded state. Status changes use polite live-region announcements; per-block
updates do not repeatedly interrupt VoiceOver.

### Layout placement

- Standard layout: keep the card in the existing narration section between
  metadata and scrubber/nudge content.
- Experimental layout: mount the same reusable card between experimental metadata
  and the scrubber. No separate experimental implementation or state is created.
- Compact-height layouts constrain only the expanded log, not the collapsed
  summary or transport controls.

## Lock-Screen Status

The current chapter remains the primary Now Playing title. The subtitle carries a
throttled operational summary:

- `Downloading narration model · 82%`
- `Rendering chapter 1 · 8 of 19`
- `Rendering chapter 4 · 63% · 1 ready ahead`
- `Waiting for chapter 3 · rendering 71%`
- `Chapter 3 ready · resuming`
- `All narration rendered`
- `Narration failed · <localized summary>`

Now Playing metadata updates are coalesced to meaningful percentage/block/state
changes rather than every downloaded chunk. Starting a rendered track must not
permanently clear a still-relevant render/buffer subtitle.

## Lifecycle Data Flow

1. `PlayerModel.startNarrationPlayback` creates the session immediately and records
   planning before awaiting import, block lookup, pronunciation resources, or plan
   preparation.
2. The progress-reporting engine preparation path reports cache check, byte
   delivery, validation, session load, and readiness. The non-reporting Now Playing
   prewarm is removed; preparation starts from an explicit narration request so the
   model cannot download silently before the session card appears.
3. `NarrationService` reports a render-unit start and structured speakable-block
   progress. The player records finalization and insertion when a durable file
   becomes playable.
4. `PlaybackController` reports play/pause/advance and exposes a narrow queue-wait
   transition for narration. The player updates buffer counts after every insertion
   and track change.
5. When a queue wait ends, the state records readiness and resumption before
   advancing to the new track.
6. Rendering completion releases the ONNX sessions as today but leaves playback
   and event history intact. Natural audio completion updates playback separately.
7. Cancellation and failures terminate only the relevant active operation and
   leave enough state/history visible to diagnose the stop.

## Error and Cancellation Behavior

- Network, validation, model-load, synthesis, file-finalization, and playback
  errors set a concrete failed state and append an error event.
- A failure never leaves the card on an active spinner.
- Task cancellation caused by book switch is recorded as cancellation before the
  old session is discarded; stale callbacks remain rejected by the existing
  `NarrationOperationToken` checks.
- Paywall termination is represented as an intentional blocked/failure outcome,
  not as a mysterious render stop.
- A no-text book records `No text to narrate` as a terminal outcome.
- Slow work reports elapsed time. It is not misclassified as failed without an
  actual error or cancellation.

## Testing and Acceptance

Implementation follows focused red-green tests before production changes.

### Unit and presentation tests

- simultaneous playing and rendering produces a combined summary;
- download byte counts, clamping, percentage, and human-readable formatting;
- cached-model, model-load, and ready transitions;
- event ordering, 200-event retention, privacy-safe developer payloads, and
  progress milestone coalescing;
- render block counts and elapsed-no-update presentation;
- accurate buffer counts from playable queue entries;
- user/system pause differs from queue-underrun waiting;
- waiting -> ready -> automatic-resume ordering;
- render completion differs from playback completion;
- cancellation, no-text, paywall, and failure terminal states;
- the standard and experimental iOS layouts both mount the reusable card;
- collapsed and expanded accessibility labels and expanded state;
- lock-screen formatting and update throttling.

### Verification sequence

1. Run the narrow narration-state, progress-formatting, render-policy, playback,
   and layout tests through the repository's Apple build-slot wrapper.
2. Run the full `make test` gate through the wrapper.
3. Build and launch the iOS app in Simulator, then inspect both standard and
   experimental layouts with deterministic injected narration states before any
   optional real-model run.
4. Exercise a real download/render when resources and schedule permit, confirming
   card, event history, lock-screen subtitle, queue wait, and auto-resume.
5. Report Simulator, real-device, model-download, and hosted-CI evidence as
   separate acceptance states.

### User-visible acceptance criteria

- The narration card is visible and updating in both iOS player layouts after
  narration begins.
- A first-time model delivery shows bytes and percent before synthesis begins.
- While audio plays, the card states what is rendering and how much playable audio
  is ready ahead.
- When playback stops at an empty rendered queue, the card explicitly says it is
  waiting for rendering; when rendering finishes, it records and displays the
  automatic resume.
- Expanding Details shows enough ordered events to explain the current state.
- The same lifecycle can be followed in unified logs without exposing private book
  content or paths.
- Completion, cancellation, and failure remain visible instead of collapsing to an
  empty card.
