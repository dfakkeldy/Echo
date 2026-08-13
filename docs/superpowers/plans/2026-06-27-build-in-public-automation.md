# Build-in-Public Automation Plan

**Date:** 2026-06-27
**Status:** Umbrella operating kit implemented in `docs/superpowers/build-in-public/`; weekly devlog PR automation implemented for Echo, MacroMark, NS Marks The Spot, Routey, and Turn Timer
**Launch window:** July/August 2026 launch-readiness batch; gate-driven, not fixed-date
**Capacity:** 2-3 hours/week

## Implemented Umbrella

The shared build-in-public home is now:

- [Umbrella README](../build-in-public/README.md) — operating cadence, source order, platform policy, and automation boundaries.
- [App roster](../build-in-public/app-roster.md) — cross-app readiness matrix for Echo, MacroMark, NS Marks The Spot, Routey, Turn Timer, and future candidates.
- [July 2026 calendar](../build-in-public/calendar-2026-07.md) — first monthly content calendar and draft queue.
- [Post formats](../build-in-public/post-formats.md) — reusable shells for weekly notes, community posts, demo captions, launch posts, monthly ledgers, and replies.
- [Review checklist](../build-in-public/review-checklist.md) — required accuracy, proof, privacy, community-fit, and tone gates.

The files live in Echo for now because this is the active workspace. They are written so the folder can move to a dedicated private/shared launch repo later.

## Goal

Keep the public story for Echo, MacroMark, NS Marks The Spot, Routey, Turn Timer, and the other release candidates moving without turning social media into a second job. The automation should prepare honest weekly material from the work that actually happened; the maintainer keeps approval over anything posted to a platform.

## Operating Principles

- The repo is the source of truth. Devlogs, release notes, and planning docs are generated from commits and merged work, not from memory.
- Generated copy is a draft unless it is limited to a clearly marked digest block.
- No unattended social posting for now. Reddit, X, TikTok, Bluesky, and Mastodon all get review gates.
- Prefer one monthly batching session plus a short weekly check-in over daily context switching.
- Keep platform participation narrow enough to be tolerable: useful posts in relevant communities beat broad broadcasting.

## Platform Plan

| Surface | Role | Automation level |
|---|---|---|
| GitHub Pages devlogs | Primary public build record | Auto-update generated weekly blocks by PR |
| GitHub PR bodies | Review inbox for weekly copy | Checklist plus AI-assisted draft when `OPENAI_API_KEY` is configured |
| GitHub releases/README/planning docs | Proof and context | Draft updates from commits, human review |
| Reddit | Careful community posts only | Draft posts; manual posting and replies |
| X | Optional official account for launch discoverability | Draft short updates; manual scheduling/posting |
| Bluesky/Mastodon | Optional lower-pressure developer/community mirrors | Draft from the same source as X |
| TikTok/short video | Defer unless a repeatable demo format appears | Manual only |

## Phase 1: Devlog Automation

- Add a deterministic `doc_automation.devlog` generator.
- Add `doc_automation.curate_devlog` to create review-ready PR bodies.
- Update each public devlog page with a marked weekly digest block.
- Schedule GitHub Actions for Mondays at 1:00 AM America/Halifax.
- Open PRs against the repo's active base branch; do not push directly to a release train.
- Keep long-form hand-written devlog notes intact below the generated block.

## Phase 2: Multi-App Content Calendar

- Shared monthly content calendar created for July 2026.
- Each app has a readiness row for release target, audience, proof points, demo assets, and safe claims.
- One month of draft slots is grouped by week and platform.
- Review checklist now gates shipped/coming distinction, screenshot freshness, private data, and exaggerated claims.

## Phase 3: Platform Accounts and Posting

- Create official app/company accounts where useful.
- Reserve handles before launch even if posting stays light.
- Start with GitHub + devlogs + one or two carefully chosen communities.
- Add X/Bluesky/Mastodon only after the drafting workflow feels repeatable.
- Treat Reddit as relationship work, not distribution machinery.

## Next Decisions

- Decide whether to keep the umbrella kit in Echo or move `docs/superpowers/build-in-public/` to a private/shared launch repo.
- Add fresh screenshots or clips for MacroMark, NS Marks The Spot, Routey, and Turn Timer.
- Add each repository's `OPENAI_API_KEY` Actions secret if AI-assisted PR drafts should run automatically.
- Duplicate `calendar-2026-07.md` into an August calendar during the first August batching session.
