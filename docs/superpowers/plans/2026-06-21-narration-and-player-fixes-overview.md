# Overnight Investigation — Narration & Player Fixes (2026-06-21)

> **What this is:** Dan asked (before bed) to investigate seven reported issues and "wake up to a PR full of plan docs," **without changing any code** (other narration work was in flight — PRs [#126](https://github.com/dfakkeldy/Echo/pull/126), [#127](https://github.com/dfakkeldy/Echo/pull/127)). This PR contains **plan docs only**. Each issue was investigated by a dedicated read-only agent that traced the real code; every plan cites verified `file:line` and follows TDD with bite-sized tasks.

> **Decisions:** Dan was asleep and couldn't answer questions, so each plan makes a documented **default decision** and lists **Open questions for Dan** to course-correct. Nothing here is committed to code — these are starting points to approve/adjust, then execute.

## TL;DR of what's wrong and the fix

| # | Issue (Dan's words) | Root cause (verified) | Fix size | Plan |
|---|---------------------|------------------------|----------|------|
| 1 | "Narration… pretty slow — Fox Reader was a lot quicker" | Whole chapter renders before first audio; ORT session has zero tuning (no threads/graph-opt/XNNPACK) | Med (2 phases) | [performance + streaming](2026-06-21-narration-performance-streaming.md) |
| 2 | "Add all the voices" (only 1 wired) | `VoiceCatalog.all` trimmed to `af_heart`; engine is already voice-agnostic; cache keys already voice-keyed | Med | [all voices](2026-06-21-narration-all-voices.md) |
| 3 | "'Jacqui'… leaving a silent piece of audio… should be at least tried" | OOV fallback is a stub returning `❓`, which the vocab drops → silence | Small | [OOV fallback](2026-06-21-narration-oov-pronunciation-fallback.md) |
| 4 | "Last word in each card stays highlighted" + "highlighted word changes font" | iOS retint never clears the previous cell; highlight adds a `.semibold` font run (metrics shift) | Small | [karaoke fixes](2026-06-21-karaoke-highlight-fixes.md) |
| 5 | "Tapping a card doesn't start playback from that location" | Tap calls the bare seek (no play/refresh); un-timed blocks silently no-op; no active-block set | Small–Med | [tap to seek](2026-06-21-readalong-tap-to-seek.md) |
| 6 | "Sleep timer icon… doesn't have the accent colour… bottom toolbar maybe too" | Sleep-pill **inactive** branch hardcodes `.secondary`; bottom toolbar grey is **intentional** (not a bug) | One line | [theming](2026-06-21-now-playing-theming-fixes.md) |

## How the seven issues map to six plans

Dan listed seven things; issues 4a (stuck highlight) and 4b (font shift) are one plan because they live in the same karaoke render path. So: **6 plan docs**, one per code cluster.

## The headline findings

- **Narration slowness is architectural, not the model.** The engine never streams — it renders the *entire first chapter* before playing a single word ([PlayerModel+Narration.swift:234-254](EchoCore/ViewModels/PlayerModel+Narration.swift)). At RTF ≈ 0.5 that's ~150 s before audio on a 5-min chapter. Fox feels "instant" because it plays the first sentence while the rest renders. **Biggest win = first-sentence streaming; cheapest win = tuning the ONNX session** (it currently uses bare `ORTSessionOptions()` — no thread count, no graph optimization, no XNNPACK).
- **Two bugs are "un-stub a deliberate seam," not new code.** The single voice (`VoiceCatalog`) and the silent OOV word (`EnglishFallbackNetwork` returning `❓`) are both leftovers from dead pivots (FluidAudio; MLX/BART). The extension points already exist — low-risk.
- **Three are small view-layer fixes.** Karaoke highlight (clear the previous cell; stop changing font weight), tap-to-seek (use the canonical `seek(toSeconds:)` + `play()` + set active block + fallback), and the sleep-timer tint (one line: `.secondary` → the cover accent).
- **One user hunch was half-wrong (good to know):** the bottom toolbar **is** themed — its grey is the deliberate "active = filled chip shape, not color" design ([BottomToolbarView.swift:54](EchoCore/Views/BottomToolbarView.swift)). Only the sleep-timer icon is an actual bug.

## Suggested execution order (when you're back)

1. **Quick wins first (small, high satisfaction):** #6 sleep-timer (1 line), #4 karaoke (color-only + clear), #3 OOV fallback.
2. **#5 tap-to-seek** (small–med; nice UX restore).
3. **#1 narration speed** — Phase 1 ORT tuning (cheap, measure RTF on the A14), then Phase 2 streaming as its own PR.
4. **#2 all voices** — needs the one-time Python converter + bundling; largest asset change.

Each plan is independent and PRs against **`nightly`** (per the promotion ladder). All are designed to be run via `superpowers:subagent-driven-development`.

## Cross-cutting notes
- **Cross-platform:** #1 (engine), #2 (catalog), #3 (G2P) are shared → land iOS + macOS at once. #4 and #5 need a matching macOS edit (parity reviewer). #6 is iOS-only by design. None affect watchOS/Widget. Run `cross-platform-parity-reviewer` on #4/#5.
- **Schema:** none of these require a DB migration as scoped (voice stays global; per-book voice is a deferred additive option).
- **Doc-sync:** #1 (streaming) and #2 (voices) are feature/architecture changes → update ARCHITECTURE.md / README.md / CHANGELOG via the `doc-sync` skill, and fix the stale FluidAudio comment in `VoiceCatalog.swift`.
- **Constraint honored:** no source files were modified in producing this PR — only these plan docs under `docs/superpowers/plans/`.

## Open questions consolidated (top priorities for Dan)
1. **Streaming shape (#1):** tiny-intro-track (recommended, protects read-along anchors) vs true single-file streaming? And acceptable first-word target (~1–2 s warm)?
2. **Voices (#2):** global vs per-book? all ~54 (~27 MB) vs a curated subset? OK to add a `Tools/` Python converter?
3. **OOV (#3):** digraph heuristic (recommended) vs plain spell-out for the immediate non-silence floor?
4. **Bottom toolbar (#6):** keep inactive chips grey (deliberate) or tint them muted?

Per-plan Open Questions live at the top of each doc.
