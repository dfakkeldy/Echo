# Build-in-Public Umbrella

**Owner:** David Fakkeldy
**Status:** Active operating kit
**Cadence:** One monthly batching session, one short weekly refresh
**Scope:** Echo, MacroMark, NS Marks The Spot, Routey, Turn Timer, and any other app moving toward a public launch or beta

This folder is the cross-app build-in-public planning home. It lives in the Echo
repo for now because this is the active workspace, but it is intentionally
written as an umbrella kit that can move to a private/shared launch repo later.

## What This Solves

The goal is to make public progress visible without creating another daily job.
The system turns merged work, devlogs, screenshots, and short demos into
reviewable drafts. Nothing posts itself. Every public-facing claim still gets a
human pass for accuracy, privacy, and tone.

The weekly app-level automation now opens a devlog PR with a checklist and, when
`OPENAI_API_KEY` is configured in GitHub Actions secrets, an AI-assisted draft
for the devlog plus short social copy. Without the secret, the PR still carries
the deterministic factual digest and review checklist.

## Operating Rhythm

| When | Timebox | Action | Output |
|---|---:|---|---|
| First weekend of the month | 90 minutes | Refresh app roster, choose the month themes, draft platform copy | Updated monthly calendar |
| Monday after weekly devlog | 20 minutes | Pull the latest shipped proof from devlogs/commits | One weekly build note draft |
| Friday or Sunday | 20 minutes | Pick screenshots/clips and approve next week posts | Scheduled/manual-ready drafts |
| Launch week | 45 minutes daily | Tighten claims, reply to real questions, retire stale drafts | Accurate launch copy |

## Source Order

Use sources in this order when drafting:

1. Merged code and release notes.
2. Generated or hand-written devlog entries.
3. Screenshots, videos, and TestFlight notes.
4. Planning docs, only when clearly labeled as coming/roadmap.
5. Memory, only after checking against one of the above.

## Folder Map

| File | Purpose |
|---|---|
| [app-roster.md](app-roster.md) | The current cross-app launch/readiness matrix. |
| [calendar-2026-07.md](calendar-2026-07.md) | The first monthly content calendar for the July/August launch-readiness window. |
| [post-formats.md](post-formats.md) | Reusable post formats for GitHub, Reddit, X, Bluesky/Mastodon, and short video. |
| [review-checklist.md](review-checklist.md) | Required pre-post review gates. |

## Platform Policy

| Platform | Role | Posting mode |
|---|---|---|
| GitHub Pages/devlogs | Primary public proof ledger | Automated digest by PR, human narrative |
| GitHub PR bodies | Weekly review inbox | AI-assisted draft and manual checklist |
| GitHub releases/README | Release proof and durable context | Draft then human merge |
| Reddit | Community conversation | Manual posting only |
| X | Optional launch discoverability | Draft and manually schedule/post |
| Bluesky/Mastodon | Lower-pressure mirrors | Draft from X copy, manually post |
| TikTok/short video | Demo-only if repeatable | Manual only |

## Guardrails

- Do not claim something shipped unless it is merged and available in the relevant build.
- Label roadmap, in-progress, and prototype work plainly.
- Do not post private repo paths, signing details, unreleased pricing, private analytics, tester identities, or screenshots containing personal content.
- Do not cross-post into communities unless the post is useful even if nobody installs the app.
- Keep posting volume small enough that replies can be handled.

## Monthly Batching Recipe

1. Open [app-roster.md](app-roster.md) and update each app's current state.
2. Pick one proof point per app for the month.
3. Choose the platform lanes for that month; default to GitHub plus one community lane.
4. Fill [calendar-2026-07.md](calendar-2026-07.md) or create the next month from the same shape.
5. Draft posts using [post-formats.md](post-formats.md).
6. Run every draft through [review-checklist.md](review-checklist.md).

## Promotion Rule

Automation may prepare:

- Devlog digest blocks.
- Lists of merged changes.
- Draft post shells.
- Reminder checklists.

Automation may not:

- Post to social accounts.
- Reply to people.
- Invent proof points.
- Convert roadmap items into shipped claims.
- Decide that a community is appropriate for a post.
