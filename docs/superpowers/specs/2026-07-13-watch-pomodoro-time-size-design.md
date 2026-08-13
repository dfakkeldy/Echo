# Watch Pomodoro Time Size Design

**Date:** 2026-07-13

## Context

The two-digit Pomodoro time in the Watch player's top-right 40-point control
currently prefers a rounded bold `.title2` font. Although the digits fit, they
sit too close to the control's five-point progress ring. The scrolling
audiobook title is intentionally unchanged.

## Design

Make `.headline` the largest Pomodoro digit style. Preserve the rounded design,
bold weight, monospaced digits, single-line presentation, and semantic Dynamic
Type behavior. Keep `.subheadline` and `.caption` as ordered `ViewThatFits`
fallbacks for constrained accessibility sizes.

Do not change the progress ring, control dimensions, Pomodoro timing,
persistence, picker limits, gestures, haptics, or VoiceOver semantics.

## Verification

- Update the focused source contract to require `.headline` and reject the old
  `.title2` preference.
- Run the Pomodoro presentation and source-contract tests.
- Build the Watch app through the repository's memory-pressure gate.
- Inspect the existing real-size 40-point, 25-minute preview or the equivalent
  Watch Simulator surface to confirm improved ring clearance without clipping.

## Success Criteria

- The visible `25` is clearly smaller than the current `.title2` presentation.
- The time remains legible, centered, and unclipped inside the 40-point control.
- Larger Dynamic Type settings continue to select a fitting semantic fallback.
- No title, timer-behavior, ring, interaction, or accessibility behavior changes.
