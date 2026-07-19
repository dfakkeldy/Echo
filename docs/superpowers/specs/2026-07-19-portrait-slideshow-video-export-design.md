<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Portrait Slideshow Video Export — Design

**Date:** 2026-07-19
**Status:** Approved in brainstorming on 2026-07-19; awaiting written-spec review
**Base:** `origin/nightly` at `5d473246`
**Depends on:** slideshow video export pipeline and CLI (PR #460), code-block visual narration (PR #461), and iOS/macOS video export interfaces (PR #462)
**Extends:** `docs/superpowers/specs/2026-07-18-slideshow-video-export-design.md`

## Goal

Add a production-quality 9:16 video option intended for full-screen phone
viewing without disturbing Echo's existing Landscape default, output bundle,
timing, audio, sidecars, cancellation, cleanup, or publication behavior.

V1 has two first-class presets:

| Format | Dimensions | Layout profile | Default |
|---|---:|---|---|
| Landscape | 1920×1080 | Legacy Landscape | Yes |
| Portrait | 1080×1920 | Phone Portrait | No |

The CLI continues to accept custom `--size WxH` dimensions. Custom dimensions
select a layout profile by orientation: `width >= height` uses Legacy
Landscape; `height > width` uses Phone Portrait. Square therefore resolves to
Legacy Landscape deterministically.

V1 deliberately implements aspect-aware profiles, not a public template
system. Its internal layout specification is designed as an upgrade seam for
additional built-in profiles and, only if later requirements justify it, a
versioned template system.

## Product decisions

- Portrait means only 1080×1920 (9:16) in v1.
- Landscape remains the CLI and UI default for every new export.
- UI format selection is not persisted in v1.
- `--portrait` and an explicit `--size` are mutually exclusive.
- Custom dimensions select their profile by orientation, not by nearest preset
  ratio.
- Images and cover art remain aspect-fit and uncropped.
- Code listings render as code in both formats instead of falling through to
  cover art.
- Long text uses bounded fitting and explicit overflow behavior; it never
  silently draws outside its region.
- Output filenames do not gain automatic `Landscape` or `Portrait` suffixes.
- SRT, chapter-list, audio, timing, cancellation, cleanup, and chapter-atom
  policies do not depend on format.

## Chosen architecture

The existing pipeline remains authoritative:

```text
VisualListeningCueResolver
        ↓
SlideshowExportPlanner
        ↓
SlideshowFrameRenderer
        ↓
VideoExportService
        ↓
MP4 + SRT + chapters.txt
```

Portrait adds configuration and layout policy around that pipeline rather than
forking it.

### `SlideshowVideoFormat`

A shared, pure, `CaseIterable` value represents the two UI presets:

- `.landscape` → 1920×1080
- `.portrait` → 1080×1920

It supplies localized presentation identity separately from its pixel
dimensions. The UI uses this type; the CLI may resolve either a preset or a
custom size.

### `SlideshowVideoDimensions`

A shared, pure, `Equatable` and `Sendable` value owns:

- `width` and `height`;
- the Landscape and Portrait constants;
- parsing of custom `WxH` input;
- validation;
- derived `SlideshowFrameLayoutProfile`.

Its stored initializer is not exposed. Landscape and Portrait are known-valid
constants; custom dimensions use a throwing factory that returns either a
validated value or `SlideshowVideoDimensionError`. It is therefore impossible
to pass an invalid `SlideshowVideoDimensions` value into `VideoExportService`
or `SlideshowFrameRenderer`. Fixed presets and custom CLI sizes share the same
validation and profile-selection rules.

`SlideshowVideoDimensionError` is a shared, pure, `LocalizedError`, `Equatable`,
and `Sendable` error with one case per product-validation rule. CLI maps it to
`ValidationError`; platform UI uses its localized description if a future
caller supplies custom dimensions. Encoder capability remains a distinct
service-level error because it depends on the live AVFoundation environment.

### `SlideshowFrameLayoutProfile`

The internal layout profile has two cases:

- `.legacyLandscape`
- `.phonePortrait`

Profile selection is solely `width >= height` versus `height > width`. A
custom 1080×1920 request and the Portrait preset produce the same layout.

### `SlideshowFrameLayout`

`SlideshowFrameLayout` is a pure calculated value containing:

- canvas bounds;
- figure/code rectangle;
- caption rectangle;
- subtitle rectangle;
- outer inset and inter-region gap;
- preferred and minimum caption, subtitle, and code font sizes;
- caption and subtitle line limits;
- code-card content insets and optional language-label metrics.

It is calculated from validated dimensions plus a profile. The initializer
enforces these invariants:

1. Every rectangle has finite, non-negative geometry.
2. Every rectangle is contained by the pixel canvas.
3. Figure/code, caption, and subtitle rectangles do not overlap.
4. Their vertical order is subtitle, caption, then figure/code in CoreGraphics'
   bottom-left coordinate system.
5. Typography is finite, positive, and no smaller than its declared minimum.

The renderer consumes the layout; it no longer invents geometry.

### Internal layout specification and future templates

The calculator is driven by a private/internal value-semantic layout
specification rather than hard-wired conditionals spread through the renderer.
In v1, only the two built-in specifications exist. The specification is not
public API, persisted data, package metadata, or user-editable configuration.

The intended evolution path is:

1. V1: two built-in aspect-aware profiles.
2. Later, if required: more built-in profiles using the same calculator.
3. Only after requirements exist: promote the internal specification into a
   versioned template schema with migration and authoring rules.

Any future template must still produce `SlideshowFrameLayout` and must not own
audio, timing, planner, SRT, chapter, cancellation, or destination behavior.
This keeps visual customization isolated from export correctness.

## Frame-plan visual-content parity

PR #461 made live Visual Listening cues image-or-code through
`VisualListeningVisualContent`, but the exporter currently stores only
`imagePath` in `SlideshowFramePlan`. A code cue therefore becomes `nil` and the
renderer shows cover art.

The frame plan will carry `VisualListeningVisualContent?` rather than only an
image path. Planner timing, frame boundaries, subtitle selection, and SRT
generation remain unchanged. Frame merging compares the full visual payload,
caption, subtitle, and emphasis state.

Renderer base-frame caching keys the complete visual payload and caption. An
image payload resolves and draws the image; a code payload draws a static code
card; no payload uses cover art. An unreadable image also falls back to cover
art. If cover art is absent, the figure region remains the existing dark
background.

For a code payload, the ordinary caption region is deliberately left empty.
Current code cues derive caption and subtitle from the same short narration
text, so drawing both would duplicate `Listing…`-style copy. The subtitle region
is the sole narration-cue surface; the optional language label remains inside
the code card. The empty caption region stays reserved so layout never shifts.

This is an intentional Landscape correction for code cues. It is not a
Portrait-only behavior because changing a book's semantic visual content by
orientation would be incorrect.

## Exact layout policy

All ratios below operate in output pixels. Fractional CoreGraphics geometry is
permitted. Legacy Landscape does not integralize or otherwise perturb the
current formulas.

### Legacy Landscape

For canvas width `W`, height `H`, and `M = 0.05H`:

| Region/metric | Formula |
|---|---|
| Subtitle rect | `(M, M, W - 2M, 0.13H)` |
| Caption rect | `(M, 0.18H, W - 2M, 0.08H)` |
| Figure/code rect | `(M, 0.31H, W - 2M, 0.64H)` |
| Caption font | `0.024H` |
| Minimum caption font | `0.019H` |
| Caption line limit | 3 |
| Subtitle font | `0.030H` |
| Minimum subtitle font | `0.024H` |
| Subtitle line limit | 4 |
| Preferred code font | `0.026H` |
| Minimum code font | `0.020H` |

These are algebraically identical to the current renderer. At 1920×1080 they
produce:

- margin: 54;
- subtitle: `(54, 54, 1812, 140.4)`;
- caption: `(54, 194.4, 1812, 86.4)`;
- figure/code: `(54, 334.8, 1812, 691.2)`;
- preferred/minimum caption font: 25.92/20.52;
- preferred/minimum subtitle font: 32.4/25.92;
- preferred/minimum code font: 28.08/21.6.

Every validated custom size with `width >= height` uses these exact formulas.

### Phone Portrait

For canvas width `W`, height `H`, short side `S = min(W, H)`, outer margin
`M = 0.05S`, and gap `G = 0.025S`:

| Region/metric | Formula |
|---|---|
| Subtitle rect | `(M, M, W - 2M, 0.30S)` |
| Caption rect | `(M, M + 0.30S + G, W - 2M, 0.14S)` |
| Figure/code origin Y | `caption.maxY + G` |
| Figure/code height | `H - M - figureOriginY` |
| Figure/code rect | `(M, figureOriginY, W - 2M, figureHeight)` |
| Preferred subtitle font | `0.045S` |
| Minimum subtitle font | `0.036S` |
| Preferred caption font | `0.034S` |
| Minimum caption font | `0.028S` |
| Preferred code font | `0.030S` |
| Minimum code font | `0.026S` |
| Subtitle line limit | 4 |
| Caption line limit | 3 |

At 1080×1920 this produces:

- margin: 54;
- gap: 27;
- subtitle: `(54, 54, 972, 324)`;
- caption: `(54, 405, 972, 151.2)`;
- figure/code: `(54, 583.2, 972, 1282.8)`;
- preferred/minimum subtitle font: 48.6/38.88;
- preferred/minimum caption font: 36.72/30.24;
- preferred/minimum code font: 32.4/28.08.

Phone Portrait uses the same formulas for every validated custom size with
`height > width`. It does not pretend that 4:5 or other custom ratios have a
dedicated optimized profile.

## Image and fallback behavior

- Portrait, landscape, and square source images are centered and aspect-fit
  using `min(regionWidth/imageWidth, regionHeight/imageHeight)`.
- Images are never cropped, stretched, blur-filled, or used as a background
  extension.
- EXIF orientation handling remains intact.
- Missing or undecodable figure files fall back to aspect-fit cover art.
- Frames without an active visual also use cover art.
- If no cover art is available, the figure region stays dark; caption and
  subtitle rendering continue.
- The visual region remains reserved even when empty, so other regions never
  move between frames.

## Caption and subtitle overflow

CoreText measures text before drawing. Drawing outside or silently clipping at
the region boundary is forbidden.

### Caption

The renderer tries the preferred caption size and reduces it only as far as the
profile minimum. If the caption still exceeds the profile line limit or
rectangle, it truncates at a composed-character boundary and draws a visible
trailing ellipsis. The source caption is not mutated.

Legacy Landscape retains its current rectangle and preferred size. Its
minimum-size and ellipsis policy applies only when content would otherwise
overflow, making this a narrow intentional improvement rather than a general
layout change.

### Simple subtitle mode

The renderer applies the same preferred-to-minimum fitting process. If the
complete block still does not fit, it truncates at a word boundary with a
visible trailing ellipsis. The `.srt` cue remains complete and untruncated.
Simple mode remains one rendered subtitle state per planner frame; text fitting
does not subdivide timing or add frames.

### Karaoke subtitle mode

If the complete subtitle fits, it renders normally. If it does not fit, the
renderer divides the subtitle into stable, word-aligned pages that fit the
profile's subtitle line limit at no less than the minimum font size. It shows
the page containing `activeWordIndex`; a page stays unchanged until the active
word crosses its boundary. The first and last visible pages use leading or
trailing ellipses when undisplayed text exists.

Page boundaries are calculated once per subtitle/layout/font combination using
conservative metrics that treat every token as bold and reserve the width of
any required leading/trailing ellipsis. Applying heard and active styling
cannot therefore change line wrapping or page membership.

Heard and active-word styling continues to use the original full-subtitle word
indices, mapped into the displayed page. Heard words keep the existing wash;
the active word keeps the existing bold/full-opacity emphasis. A valid active
word is therefore always visible. If no valid active-word index exists, the
renderer uses the Simple fitting policy for that frame.

The rolling window changes pixels only for subtitles that currently overflow.
It does not change planner frames, timestamps, audio, or SRT cues.

## Code-card behavior

Code uses the figure rectangle rather than the caption or subtitle rectangle.
The card has a restrained lighter surface on the existing dark background,
internal padding derived from the short canvas side, and an optional
top-leading language label when the cue supplies a non-empty language.

For both profiles, let `S = min(W, H)`. The code card fills the figure/code
rectangle and uses content padding `P = 0.025S`. The optional language label
uses font size `L = 0.022S`, a line box of `1.25L`, and a gap of `0.0125S`
before the code text. Without a language label, the code content rectangle is
the card inset by `P` on every edge. With a label, the label occupies the
top-leading padded line box and the code content begins below that box and its
gap. Both rectangles remain inside the card.

- Code is monospaced and top-leading.
- Source line breaks and indentation are preserved.
- Lines do not wrap.
- The renderer starts at the preferred code size and may reduce only to the
  profile minimum.
- A line wider than the content width receives a visible trailing ellipsis.
- If more source lines exist than fit vertically, the final visible row is an
  ellipsis marker.
- The card is static; it does not scroll or paginate because the planner has no
  line-level code timing.
- Caption and subtitle retain their own non-overlapping regions.
- Karaoke emphasis applies to the subtitle, never to raw code tokens.

This policy makes code meaningfully visible in standard video while remaining
deterministic and honest about static-video limitations.

## Dimension validation

Product validation is owned by the throwing `SlideshowVideoDimensions` factory.
CLI custom sizes are validated before opening the database or creating the
output directory. UI presets are compile-time known-valid constants. Service
and renderer accept only the validated value.

Dimensions must satisfy every rule:

1. Width and height are positive integers.
2. Width and height are even, as required by Echo's H.264 path.
3. `min(width, height) >= 180`.
4. `max(width, height) <= 4096`.
5. `width × height <= 4096 × 2160` (8,847,360 pixels).
6. `max(width, height) / min(width, height) <= 4.0`.

The area calculation uses overflow-safe integer arithmetic. Validation reports
the first failed rule in the order above.

This intentionally tightens the old custom-size contract, which accepted any
positive pair and delegated failures to AVFoundation. Existing practical
dimensions including 320×180, 640×360, 1920×1080, 1080×1920, 3840×2160, and
2160×3840 remain valid. Previously accepted odd, tiny, extreme, or unsafe
dimensions now fail before export with an actionable explanation.

### H.264 capability preflight

Product-valid dimensions do not guarantee that the live encoder accepts the
derived H.264 settings. At the very beginning of `VideoExportService`, before
source resolution, database reads, audio assembly, or named output creation,
Echo creates the proposed video settings and runs AVFoundation's
`AVAssetWriter.canApply(outputSettings:forMediaType:)` capability check. Any
temporary writer URL used for that query is unique and removed defensively.

Failure produces a distinct localized/actionable
`VideoExportService.ExportError.unsupportedVideoSettings(width:height:)` and no
book/output work begins. The same settings object is later supplied to the real
writer so the preflight cannot validate one configuration and encode another.
Writer failures remain possible and continue to surface their underlying
errors.

## CLI behavior

The command remains:

```text
echo-cli export-video ... [--portrait] [--size WxH]
```

Resolution rules are exact:

| Invocation | Result |
|---|---|
| neither option | 1920×1080, Legacy Landscape |
| `--portrait` | 1080×1920, Phone Portrait |
| `--size 1920x1080` | 1920×1080, Legacy Landscape |
| `--size 1080x1920` | 1080×1920, Phone Portrait |
| any valid custom `--size` | requested pixels; profile selected by orientation |
| `--portrait` plus any explicit `--size` | validation error; no precedence |

`--size` becomes optional internally so ArgumentParser can distinguish an
explicit value from the default. The user-visible default remains Landscape.
Existing scripts using `--size 1920x1080` continue to work. Existing custom
portrait scripts keep their dimensions but intentionally receive the new
Phone Portrait layout.

Custom-size spelling retains the existing lowercase `x` separator. Uppercase
`X`, missing components, whitespace-only components, and non-integer values
remain invalid.

Argument errors are direct and actionable:

- `--portrait cannot be used with --size; choose one format option.`
- `--size must look like 1920x1080.`
- `Video width and height must both be even for H.264.`
- `Video's shortest side must be at least 180 pixels.`
- `Video's longest side must be no more than 4096 pixels.`
- `Video dimensions exceed the maximum 8,847,360-pixel area.`
- `Video aspect ratio must not exceed 4:1.`

Dimension resolution and validation happen before opening the database or
creating the output directory. `--simple`, `--range`, cache handling, progress
output, and completion receipts are unchanged.

## iOS behavior

`VideoExportProgressView` becomes a three-state flow:

1. **Configuration:** Landscape/Portrait segmented selector, exact dimensions,
   explanatory phone-viewing copy, and an Export button.
2. **Export:** existing progress, accessibility percentage, background-task
   extension, cooperative cancellation, and cleanup.
3. **Result:** existing success/share bundle or localized error state.

The sheet no longer starts export on appearance. Each new sheet starts at
Landscape. iPhone v1 continues to use Karaoke mode and does not expose the
Karaoke/Simple choice. Dismissing during export cancels the structured task;
dismissing configuration creates no temporary output.

The Export button captures one immutable request with a unique identifier and
transitions the view to Export state. A `.task(id:)` keyed by that request runs
the export; SwiftUI therefore cancels it when the sheet disappears. The button
is disabled immediately after capture, and a second request cannot begin until
the current task reaches Result or the view is recreated. No detached or
fire-and-forget export task is introduced.

## macOS behavior

`MacVideoExportView` adds a Landscape/Portrait segmented selector alongside its
existing Karaoke/Simple selector. Both default values are visible before the
save panel. Both are captured into an immutable configuration before
`NSSavePanel` appears and are disabled while export is active.

The save-panel filename, staging directory, coordinated three-file publication,
rollback, cancellation, and Reveal in Finder behavior are unchanged. The user
chooses the movie basename; Echo does not append a format suffix.

## Accessibility and localization

- All new user-facing strings use manual symbol keys in
  `EchoCore/Localizable.xcstrings` with English and Dutch translations.
- A format control announces both identity and resolution, such as
  `Portrait, 1080 by 1920`.
- Orientation is communicated by text and dimensions, not only an icon,
  thumbnail shape, or color.
- Configuration UI uses semantic text styles and supports Dynamic Type.
- Segmented controls have explicit localized labels and accessibility values.
- Existing progress percentage, cancel, success, share, and error semantics
  remain intact.
- The exported video uses sufficient contrast for caption, subtitle, heard
  wash, active word, and code-card text. Raster tests verify distinct emphasis
  states; human phone-viewing acceptance remains a separate gate.

## Errors and recovery

Product-dimension errors come from `SlideshowVideoDimensionError` before service
entry. Live encoder rejection comes from
`VideoExportService.ExportError.unsupportedVideoSettings`. Both platform views
and the CLI map relevant errors to actionable localized copy. Existing error
behavior remains:

| Condition | Behavior |
|---|---|
| Invalid product dimensions | Throw from dimensions factory before service entry |
| H.264 settings unsupported by live encoder | Fail service preflight before source/output work |
| No alignment | Existing localized failure before rendering |
| No local audio | Existing localized unsupported-book failure |
| Missing/undecodable figure | Log and use cover art; do not abort the export |
| Missing cover art | Continue with dark visual region |
| Chapter-atom write/verification failure | Keep MP4 and `chapters.txt`; log fallback |
| Cancellation | Cooperatively stop and remove partial/staged output |
| Writer, codec, or disk failure | Surface underlying error when available and clean partial output |

Dimension validation and AVFoundation capability preflight do not replace
writer-error propagation; they prevent known unreasonable or unsupported
requests from reaching book assembly and encoding.

## Compatibility contract

| Surface | Compatibility promise |
|---|---|
| Default CLI/UI export | Remains Landscape 1920×1080 |
| Explicit `--size 1920x1080` | Continues to work and uses exact legacy layout |
| Other `width >= height` custom sizes | Keep exact legacy geometry formulas |
| `height > width` custom sizes | Keep dimensions; intentionally adopt Phone Portrait layout |
| Ordinary Landscape image frames | Pixel/layout compatible with current renderer |
| Landscape code cues | Intentional improvement: code card replaces erroneous cover-art fallback |
| Landscape overflowing text | Intentional improvement: bounded fitting/ellipsis/window replaces silent clipping |
| Image fitting | Remains uncropped aspect-fit |
| MP4 audio/timing | Unchanged |
| SRT and chapter-list contents | Independent of format; byte-identical for the same plan |
| Chapter atoms | Semantically equivalent for the same plan; MP4 bytes need not match |
| Cancellation/cleanup/publication | Unchanged |

No migration or persistence change is required.

## Testing strategy

Implementation follows strict TDD for every task: write a focused failing test,
observe the expected failure, implement the smallest coherent behavior, then
run the focused suite to green before broader verification.

### Pure format and validation tests

- Landscape and Portrait preset dimensions.
- No-option CLI request resolves to Landscape.
- `--portrait` resolves to Portrait.
- Explicit `--size` resolves to custom dimensions.
- `--portrait` plus `--size` conflicts.
- Lowercase `WxH` backward compatibility.
- Malformed, missing, negative, zero, odd, too-small, too-large, excessive-area,
  and excessive-aspect inputs.
- Boundary values at 180, 4096, 8,847,360 pixels, and 4:1.
- Portrait, Landscape, and square profile selection.
- Overflow-safe area validation.

### Pure layout tests

- Exact 1920×1080 legacy rectangles and font sizes listed in this spec.
- Exact 1080×1920 portrait rectangles and font sizes listed in this spec.
- Representative validated custom Landscape, Portrait, and square sizes.
- Boundary-size matrices proving all rectangles are finite, in bounds, ordered,
  and pairwise non-overlapping.
- Minimum typography and positive visual-region size at every accepted boundary.
- Layout specification produces the same result deterministically.

### Planner tests

- Image content continues into frame plans.
- Code content and optional language continue into frame plans.
- Frame merging distinguishes different image and code payloads.
- Raw code never leaks into SRT subtitle text.
- Simple/Karaoke timing, ranges, and track offsets remain unchanged.

### Raster tests

At both 1920×1080 and 1080×1920:

- real generated portrait, landscape, and square raster fixtures aspect-fit
  without crop;
- EXIF orientation remains correct;
- cover fallback, missing cover, and no-figure frames;
- short and long captions;
- short and long Simple subtitles;
- Karaoke pages always contain the active word and preserve heard/active visual
  differences;
- Karaoke page membership does not change when different words become bold;
- code with/without language, long lines, and excess vertical lines;
- code narration appears once in the subtitle region and is not duplicated in
  the caption region;
- every region draws only inside its declared rectangle;
- ordinary Landscape golden/pixel samples remain compatible.

Tests may generate local temporary raster fixtures but do not commit private
book media.

### CLI tests

Pure request-resolution tests cover default, Portrait, custom size, conflicts,
and invalid values. After building only through `make echo-cli`, executable
smoke tests also prove ArgumentParser binds `--portrait` and `--size` correctly,
prints the new help, rejects the conflict before database access, and retains
the existing explicit `--size 1920x1080` path.

### UI tests

- iOS opens in configuration rather than auto-starting.
- Both views default to Landscape for every new presentation.
- Both format choices and exact resolutions appear.
- VoiceOver-facing label/value includes format and dimensions.
- iPhone passes Karaoke plus the selected dimensions.
- macOS passes selected mode plus selected dimensions.
- Configuration freezes/disables once export begins.
- Existing iOS cancel/share/temporary-directory lifecycle remains intact.
- Existing macOS staging, publication, rollback, and Reveal flow remains intact.
- New localization keys are manual and have English and Dutch values.

### Service integration tests

- A synthesized fixture produces exactly 1080×1920 video as reported by
  AVFoundation.
- Video codec is H.264; audio codec is AAC; duration remains within the existing
  tolerance.
- A paired Landscape/Portrait export from the same plan produces byte-identical
  `.srt` and `.chapters.txt` files.
- Both MP4 exports retain audio, timing, cancellation, cleanup, and output
  naming behavior.
- Chapter atoms are semantically equivalent when stamping succeeds; fallback
  remains accepted and covered.
- Invalid custom dimensions fail in the shared factory and cannot enter the
  service.
- An injected/reproducible negative H.264 capability result fails before source
  resolution or output creation and reports `unsupportedVideoSettings`.

### Build and hosted gates

Every build/test command runs through:

```bash
"$HOME/.claude/bin/xcode-build-gate.sh" --wait && <build-or-test-command>
```

Focused implementation loops use `make build-tests` once, then
`make test-only FILTER=...`. The CLI is built only through `make echo-cli`.
Full iOS tests, macOS build/tests, CLI build, formatting/lint checks when
installed, and hosted `Build gate + tests` must pass before implementation is
called complete.

## Real-book acceptance

At implementation acceptance time, locate a local aligned book with varied
visual content. Do not commit or document its private path, database contents,
or media.

Export the same short representative range in:

- 1920×1080 Landscape;
- 1080×1920 Portrait.

For both outputs:

1. Inspect representative decoded frames or screenshots, including differently
   shaped images, long text, Karaoke emphasis, a code card when the chosen book
   contains one, and a cover/no-figure state when available.
2. Use `ffprobe` to verify dimensions, H.264 video, AAC audio, duration, and
   chapter metadata.
3. Inspect `.srt` and `.chapters.txt` contents and compare paired hashes/bytes.
4. Verify MP4 chapter atoms with the existing chapter-inspection tooling.
5. Record machine results separately from human viewing results.

Machine inspection proves the artifact and layout invariants. It does not prove
full-screen phone readability, full-book comprehension, device thermal
behavior, background endurance, or whole-book performance. Human viewing of a
short Portrait sample and whole-book performance on a physical iPhone remain
separate user/device gates unless explicitly authorized and completed.

## Risks and mitigations

- **Landscape drift during extraction:** exact formula tests and ordinary-frame
  pixel comparisons lock the legacy profile before renderer refactoring.
- **Karaoke window feels jumpy:** stable word-aligned pages change only at page
  boundaries rather than shifting every word.
- **Code listing loses off-screen material:** visible ellipses make truncation
  explicit; full scrolling/pagination waits for line-level timing or a later
  template requirement.
- **Custom-size compatibility tightens:** actionable early validation replaces
  writer failures; practical prior sizes remain accepted.
- **Portrait claim exceeds evidence:** machine QC and human/device acceptance are
  reported as separate proof layers.
- **Premature template architecture:** the internal specification remains small,
  private, and value-semantic; no schema, persistence, branding, or authoring UI
  ships in v1.

## Explicit non-goals

- Portrait ratios other than the 9:16 preset.
- Square, 4:5, or platform-branded presets.
- Public/user-authored templates, schema versioning, persistence, or migration.
- Social-network branding, logos, watermarks, safe-zone overlays, or metadata.
- Multiple simultaneous Landscape/Portrait outputs.
- Cropping, pan-and-scan, blur fill, Ken Burns, or other motion effects.
- Changing planner timing, audio assembly, SRT semantics, chapter-list format,
  range behavior, cancellation, cleanup, or publication.
- Embedded subtitle tracks.
- watchOS export UI.
- Claiming whole-book iPhone performance or human phone-viewing acceptance from
  automated tests.

## Implementation constraints

- Preserve iOS 18, macOS 15, watchOS 11, and the project's Swift 6.0 language
  mode while using the installed Xcode 26.6/Swift 6.3.3 toolchain.
- No new dependencies.
- Shared/export code remains free of UIKit/AppKit where the current targets
  require it.
- Every new file begins with the repository SPDX header on line 1.
- Use Conventional Commits and strict TDD.
- Base implementation on current `origin/nightly` and target PRs to `nightly`,
  never `main`.
- Use fresh focused implementation subagents and an independent review pass.
- Do not manipulate shared simulator, device, or process state.
- Follow hosted CI to green before declaring implementation complete.
