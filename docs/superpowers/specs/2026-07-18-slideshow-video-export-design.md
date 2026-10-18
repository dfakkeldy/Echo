# Slideshow Video Export with SRT — Design

**Date:** 2026-07-18
**Status:** Approved (brainstorm 2026-07-18)
**Depends on:** Visual Listening slideshow mode (`VisualListeningCueResolver`, `VisualListeningViewModel`), `AudioExportService` / `ExportSource` m4b export spine, word-level alignment (`word_timing`).

## Goal

Export a whole book's Visual Listening slideshow as a standard video file plus machine-readable subtitles, so a book can be watched and studied outside Echo. One feature serves four purposes:

1. **Watch/study outside Echo** — review a book on a TV, tablet, or any video player.
2. **Share clips** — the pipeline is range-parameterized from day one; clip UI ships later.
3. **Archive / accessibility artifact** — a durable, player-agnostic record of book + figures + captions, with correct standalone subtitles.
4. **Marketing/demo material** — high-quality renders of read-along + figures via echo-cli.

The export must look exactly like the live Visual Listening stage in structure (same figure, caption, subtitle, and word-emphasis decisions at every instant) because both are driven by the same pure resolver.

## Unit of export and output bundle

The unit of export is the **whole book**. One export produces, in a caller-chosen directory:

| File | Contents |
|------|----------|
| `<Book Title>.mp4` | 1920×1080 H.264 + AAC. Whole book, gapless, tracks in playback order. Chapter marks stamped when the MP4 chapter-atom write verifies (see Risks). |
| `<Book Title>.srt` | Sentence/block-level subtitle cues with global (whole-video) timestamps. |
| `<Book Title>.chapters.txt` | YouTube-description chapter lines: `HH:MM:SS Chapter Title`, one per chapter. Always written; also the fallback when in-container chapter atoms fail. |

Frame composition matches the live stage: figure aspect-fit on a dark background, caption beneath, subtitle band at the bottom. When word timings exist, the active word gets emphasis and already-heard text gets the wash treatment (**Karaoke mode**, default). A **Simple mode** renders one frame per subtitle block instead of per word. Books without figures still export — cover art is the standing frame — so every aligned or narrated book is exportable, not just illustrated ones.

Subtitles are delivered **both** burned into frames and as the sidecar `.srt`. SRT has no real per-word styling, so word karaoke lives only in the burned-in frames; the `.srt` carries standard block/sentence cues for players and accessibility.

### Deliberately parameterized, not yet surfaced

- **Time range**: the planner accepts an optional `[start, end)` global range (clip export later needs UI only).
- **Output size**: the renderer takes width×height (vertical/square social variants later).

### Out of scope for this slice

- Clip range picker UI, vertical/square presets, per-chapter batch files.
- watchOS anything.
- Embedded (in-container) subtitle tracks; sidecar `.srt` only.
- Ken Burns / motion effects; frames are static per cue.
- Re-exporting when alignment changes (user re-runs export manually).

## Architecture

**Chosen: pure render plan → CoreGraphics frames → AVAssetWriter.**

A pure planner turns DB rows into a deterministic timed plan; a CoreGraphics/CoreText renderer rasterizes frames; `AVAssetWriter` encodes H.264 with **variable frame durations** — one frame per visual change, not a fixed frame rate. Simple mode for a 10-hour book is on the order of 5k frames; Karaoke mode ~1–2 frames per word (~160k for an 80k-word book). Both are far below a real 30fps render, and hardware H.264 encodes near-identical frames very cheaply.

Rejected alternatives, recorded for posterity:

- **SwiftUI `ImageRenderer` reusing `VisualListeningStageView`** — pixel-perfect parity, but MainActor-bound (a whole-book render would occupy the main actor) and UIKit-coupled (three per-platform view stacks, plus the EchoCore target-exclusion trap). The planner/renderer split gets parity by sharing the *decision* layer instead of the pixel layer.
- **`AVVideoCompositionCoreAnimationTool`** — CA offline compositing is flaky headless (bad fit for echo-cli) and frame contents are untestable.

All new shared/EchoCore files are CoreGraphics/CoreText/AVFoundation only — no UIKit or AppKit — so they compile for iOS, macOS, and echo-cli without target exclusions.

## Components

### 1. `Shared/SlideshowExportPlanner.swift` (pure)

Sibling to `VisualListeningCueResolver`, which it calls. Input: visible `EPubBlockRecord`s, timeline rows, word rows, ordered track list with durations, chapter titles, sync-point preference, mode (karaoke/simple), optional global time range. Output: `SlideshowExportPlan` containing:

- `frames: [FramePlan]` — global start time, duration, image path (or `nil` → cover art), caption, subtitle text, active-word index, heard-word count, chapter context.
- `srtCues: [SRTCue]` — global start/end, text.
- `chapterMarks: [ChapterMark]` — global start time + title.

**Global timeline mapping** is this component's core job: all cue times in the DB are per-track (scoped by `segment_key` / chapter indices). The planner walks tracks in playback order, resolves cues within each track exactly as the live stage does (same resolver, same scoping), and offsets them by the accumulated duration of preceding tracks — the same accumulation `AudioExportService.exportM4B` performs for chapter atoms, so video, SRT, and audio stay in lockstep by construction.

Frame boundaries are event-driven: the union of image-cue transitions plus word boundaries (karaoke) or block boundaries (simple), clamped to the requested range.

### 2. `Shared/SRTFormatter.swift` (pure)

`HH:MM:SS,mmm` timestamps, 1-based cue numbering, blank-line separation. Long blocks are split into cues of ≤2 lines / ~42 characters per line: split points are chosen proportionally by word timings when present, evenly across the block window otherwise. Also emits the `chapters.txt` lines (`HH:MM:SS Title`).

### 3. `EchoCore/Services/Export/SlideshowFrameRenderer.swift` (CoreGraphics/CoreText)

Rasterizes one `FramePlan` into a `CVPixelBuffer`/`CGImage` at a caller-given size. Performance contract: the composed base frame (background + figure + caption) is cached per image cue and only the subtitle text band is redrawn per word, so Karaoke mode does not re-rasterize the figure 160k times. Text layout uses CoreText with semantic-ish sizing scaled to the output height (no Dynamic Type off-screen; sizes are fixed ratios of frame height).

### 4. `EchoCore/Services/Export/VideoExportService.swift` (actor)

Sibling of `AudioExportService`, reusing the `ExportItem`/`ExportSource` assembly for ordered, security-scoped audio:

1. Assemble ordered audio items (same code path as m4b export).
2. Build the plan (planner) — fail fast before any rendering if the book is unexportable.
3. `AVAssetWriter` session: H.264 video input fed frame-by-frame with explicit presentation timestamps; AAC audio input fed from an `AVAssetReader` over the audio composition.
4. Stamp chapter atoms last via `ChapterMarkerWriter` (attempt-and-verify; degrade silently to `chapters.txt`-only).
5. Write `.srt` and `.chapters.txt`.

Progress is reported via `AsyncStream<Progress>` (phase + fraction); cancellation is cooperative `Task` cancellation checked per frame, cleaning up partial output files.

### 5. Shared image-resolution helper (targeted improvement)

`VisualListeningStageView` currently contains fallback logic for resolving stored-absolute image paths whose book folder moved ([VisualListeningStageView.swift:85](../../../EchoCore/Views/VisualListeningStageView.swift)). That logic is extracted into a shared, view-free helper used by both the live stage and the renderer, so export and playback resolve images identically.

### 6. Entry points (all three in this feature, split across two PRs)

- **echo-cli**: `echo-cli export-video --book <folder> --out <dir> [--simple] [--range a-b] [--size WxH]`. Built via `make echo-cli` only (Release + incremental — see CLAUDE.md).
- **iOS**: book overflow menu → export progress sheet (progress bar, cancel) → share sheet on completion. Export runs in-app foreground with a short background-task extension; device QA on a short book gates whether Karaoke remains the iOS default or iOS defaults to Simple.
- **macOS**: tri-pane book context/overflow menu → save panel → progress → reveal in Finder.

## Error handling

| Condition | Behavior |
|-----------|----------|
| No timeline/alignment rows for the book | Fail fast with "needs alignment or narration" before rendering starts. |
| No local audio (ABS-only book) | Explicit unsupported-book error before rendering. |
| Missing/undecodable image file at render time | Log, fall back to cover art for that cue; never abort a long render for one image. |
| Chapter-atom write fails or doesn't verify | Keep the video, ship `chapters.txt`; log. Never fails the export. |
| Cancellation | Remove partial `.mp4`/`.srt`/`.chapters.txt`; return cleanly. |
| Disk-full / writer failure | Surface the underlying error; remove partial files. |

## Testing

- **Planner** (Swift Testing, fixtures like `VisualListeningCueResolverTests`): track-offset accumulation, scoping parity with the live resolver, karaoke vs simple frame density, range clamping, cover-art fallback, chapter marks.
- **SRTFormatter**: golden-file tests for timestamps, numbering, long-block splitting with and without word timings, `chapters.txt` format.
- **Renderer**: smoke tests — correct pixel size, non-blank output, distinct output for distinct active words, base-frame cache reuse.
- **VideoExportService** (integration): tiny synthesized fixture (two images + ~10s generated tone) → assert output duration, video+audio track presence, frame presentation timestamps, sidecar files' existence and content.
- **CLI**: argument parsing + unsupported-book error path.
- Full gates per CLAUDE.md: `make test`, macOS build, `make echo-cli`, SwiftLint, hosted CI.

## Slicing — two stacked PRs into `nightly`

1. **PR 1 — pipeline**: planner + SRTFormatter + renderer + `VideoExportService` + image-helper extraction + echo-cli subcommand. Fully testable headless; proves the whole pipeline end-to-end.
2. **PR 2 — UI**: iOS overflow entry + progress sheet + share sheet; macOS entry + save panel; `ARCHITECTURE.md`/`CHANGELOG.md`/docs updates.

Both can land the same day; PR 2 branches from PR 1's branch if review overlaps.

## Risks

- **iPhone whole-book Karaoke render time**: tens of minutes for a long book is plausible. Mitigations: Simple mode, progress + cancel, background-task extension; first device QA gates the iOS default mode.
- **Chapter atoms on `.mp4` video are unverified**: `ChapterMarkerWriter` targets m4a/m4b containers; `.mp4` is the same ISO-BMFF family but player behavior must be verified (QuickTime, VLC). Fallback (`chapters.txt`) is guaranteed and already needed for YouTube.
- **Word-timing gaps**: books whose word timings were interpolated (macOS CLI narration path) will show coarser karaoke; frames degrade to block-level emphasis exactly as the live stage does — no special handling.
