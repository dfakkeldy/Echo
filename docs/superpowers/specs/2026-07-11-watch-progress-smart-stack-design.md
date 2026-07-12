# Watch Progress and Smart Stack Design

**Date:** 2026-07-11
**Status:** Approved for implementation planning

## Purpose

Make Echo's Watch progress surfaces more legible without enlarging their
footprints, and add a richer Smart Stack presentation that can use the current
book cover's derived accent whenever WidgetKit permits full-colour rendering.

The work covers three related surfaces:

1. the existing circular watch-face complication;
2. a new rectangular Smart Stack/complication presentation; and
3. the Pomodoro control inside the Echo Watch app.

## Platform Constraints

- Echo targets watchOS 11 or later and Swift 6. The design must not require a
  watchOS 26-only API.
- WidgetKit does not offer full-colour rendering for
  `.accessoryCircular`. In accented or vibrant appearances, watchOS owns the
  final palette. The circular complication therefore remains watch-face tinted.
- `.accessoryRectangular` can appear in full colour in the Smart Stack. It may
  still appear accented on a watch face, so the view must support both modes.
- Echo already derives `artworkAccentColorHex`, sends it to the Watch, persists
  it in the shared App Group, explicitly clears it when artwork becomes neutral
  or unavailable, and reloads the widget. No new WatchConnectivity field is
  needed.
- The Pomodoro picker supports durations up to 23:59:59. A two-digit adaptive
  display can therefore represent its largest coarse unit as `24` when rounding
  upward.

## Widget Architecture

Keep the existing `TimelineProvider` and `StaticConfiguration`. Extend the
timeline entry with the persisted cover-accent hex, then select a focused view
from the `widgetFamily` environment:

- `EchoCircularWidgetView` for `.accessoryCircular`;
- `EchoRectangularWidgetView` for `.accessoryRectangular`.

The widget configuration supports both families. The current relevance score,
timeline cadence, deep link, and App Group remain unchanged.

### Colour Policy

Resolve the persisted `#RRGGBB` value through the existing shared `HexRGB`
parser.

- In `.fullColor`, the rectangular progress treatment uses the valid
  cover-derived accent.
- If the accent is missing or invalid, full-colour rendering falls back to the
  app/system accent.
- In `.accented` or `.vibrant`, progress uses semantic tint and joins the
  WidgetKit accent group so the watch face can apply its palette.
- The circular family always uses semantic tint because its supported
  appearances do not preserve Echo's exact RGB value.

This policy avoids a preview-only illusion in which Echo requests a cover colour
that the shipping watch face silently replaces.

## Circular Complication

Retain the current cover-or-music-note centre and total-book progress semantics.
Change only the visual weight and safe geometry:

- increase the background and active ring from 4 pt to 6 pt;
- increase the endpoint marker from 6 pt to 8 pt;
- inset the ring and its marker path by 4 pt to keep the heavier stroke inside
  the complication bounds; and
- increase artwork padding from 4 pt to 8 pt so the cover does not collide with
  the ring.

Progress remains clamped to `0...1`. The existing combined VoiceOver title,
playing/paused state, and percentage remains intact.

## Rectangular Smart Stack Presentation

The rectangular view is a glanceable playback card:

- a 44 pt rounded book cover at the leading edge, with a music-note fallback;
- a single-line book or chapter title;
- playing/paused state and whole-book percentage; and
- a bold 5 pt linear progress gauge.

In full-colour Smart Stack rendering, the gauge uses the cover-derived accent.
In accented or vibrant rendering, it uses the watch-face/system palette. The
entire card retains the existing `echoaudio://play` deep link.

VoiceOver combines the title, playback state, and percentage into one concise
element. Decorative artwork is not announced separately.

## Pomodoro Ring

Keep all existing control frames and interactions. Increase only the stroke
weight:

- top and side controls: 3.5 pt to 5 pt;
- larger centre ring: 4.5 pt to 6 pt.

The background and active arcs use the same width. The active arc continues to
use the cover-derived Watch-app accent while active and the existing inactive
colour when stopped. The long-press duration picker, tap-to-start/stop behaviour,
and ring animation remain unchanged.

## Adaptive Two-Digit Pomodoro Display

Replace the current `HH:MM`/`MM:SS` text with exactly two monospaced digits and
increase the font from 23 percent to 38 percent of the control diameter. The
visual display has no unit suffix; VoiceOver supplies the complete value, unit,
and timer state.

Use the following unit and rounding policy:

1. More than 60 minutes remaining: show hours, rounded upward.
2. From exactly 60 minutes down to more than 60 seconds: show minutes, rounded
   upward.
3. From exactly 60 seconds to completion: show seconds, rounded upward.
4. At completion: show `00`.
5. A finite positive value above 99 hours saturates visually at `99`; VoiceOver
   announces "More than 99 hours remaining." This is only a defensive rule for
   state outside the picker's 23:59:59 limit and does not alter timer timing.

Examples:

| Remaining | Visible text | Spoken value |
| --- | --- | --- |
| 2:00:00 | `02` | 2 hours remaining |
| 1:20:00 | `02` | 2 hours remaining |
| 1:00:00 | `60` | 60 minutes remaining |
| 0:25:00 | `25` | 25 minutes remaining |
| 0:01:00 | `60` | 60 seconds remaining |
| 0:00:59 | `59` | 59 seconds remaining |
| 0:00:00 | `00` | Timer complete |

The hours view is intentionally coarse. It is optimized for glanceability and
never understates the remaining time; precision increases as the timer nears
completion. This trade-off is acceptable because Pomodoro sessions are normally
minute-scale, while occasional two-hour sessions still fit the display.

### Pomodoro Accessibility

Expose the Pomodoro control as one button with localized semantics:

- label: "Pomodoro timer";
- running value: "Running, _n_ hours/minutes/seconds remaining";
- stopped value: "Stopped, _n_ hours/minutes/seconds remaining";
- completed value: "Timer complete";
- running hint: "Double-tap to stop the timer"; and
- stopped hint: "Double-tap to start the timer."

Keep the physical long press for the duration picker and add a named
accessibility action, "Set duration", that invokes the same picker callback.
This makes duration configuration discoverable without changing the visible
control or its interaction for sighted users.

## Test and Preview Strategy

Follow failing-first test development.

- Add pure tests for adaptive Pomodoro formatting at every unit boundary,
  fractional tick values, zero, invalid/negative inputs, the maximum picker
  duration, and the `99`/"more than 99 hours" saturation boundary.
- Add pure tests for ring metrics so the 5 pt/6 pt Pomodoro distinction and the
  6 pt complication style cannot regress silently.
- Extend cover-accent tests for valid, missing, invalid, and explicit-clear
  values plus full-colour versus system-tint selection.
- Add WidgetKit previews for circular and rectangular families in representative
  progress states and rendering appearances.
- Add active Pomodoro previews for the actual control/ring pairs: side `38/38`,
  top `40/40` and `42/42`, and centre `40/48` and `42/52`. Include hour,
  minute, and second display phases.
- Build and run the dedicated Watch app tests plus the relevant shared iOS test
  target through the repository's memory-pressure gate.
- Perform final physical-device checks for smallest/largest Watch layouts,
  Always On legibility, actual watch-face tinting, full-colour Smart Stack
  rendering, and VoiceOver output.

## Failure and Fallback Behaviour

- Missing or invalid cover accent: use semantic system tint.
- Missing or invalid thumbnail: show the existing music-note fallback.
- Non-finite, negative, or completed Pomodoro remainder: clamp to zero and show
  `00`.
- Progress outside `0...1`: clamp before drawing.
- Unsupported or future widget family: render the circular presentation as a
  safe default while keeping the configuration limited to the two declared
  families.

## Non-Goals

- Forcing an exact cover RGB onto an accented circular watch-face complication.
- Adding RelevanceKit, push-driven widgets, or a watchOS 26-only configuration.
- Changing Pomodoro timing, persistence, haptics, picker limits, or sighted
  tap/long-press behaviour.
- Changing the Watch app's ordinary audiobook progress ring.
- Adding an iPhone WidgetKit target.

## Acceptance Criteria

- The existing circular complication is visibly bolder and does not clip.
- The rectangular family is available and shows cover, title, state, percentage,
  and progress at a glance.
- The rectangular gauge uses the valid cover accent only in full-colour
  rendering and gracefully adopts semantic tint in system-coloured modes.
- Pomodoro rings are visibly bolder in every existing slot without changing
  control frames or overlapping adjacent controls.
- Pomodoro shows exactly two larger digits following the approved adaptive-unit
  boundaries and rounding policy.
- VoiceOver announces an unambiguous timer value and unit despite the unitless
  visual display, distinguishes running/stopped/complete state, and exposes the
  named "Set duration" action.
- Focused and full relevant tests pass, Watch and widget targets build, and
  hardware-only validation gaps are reported honestly.
