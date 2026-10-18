# Build-in-Public Calendar: July 2026

**Month goal:** Prepare a low-maintenance public trail for the July/August
launch-readiness window without over-posting or over-claiming.

**Primary lanes:** GitHub/devlog, one careful community post, optional X or
Bluesky/Mastodon mirrors.

## Themes

| Week | Dates | Theme | Primary app | Proof source | Target surface |
|---|---|---|---|---|---|
| 1 | Jul 1-5 | Set the ledger | Echo | Current devlog + first automated digest | GitHub/devlog, X/Bluesky draft |
| 2 | Jul 6-12 | Show the daily-use loop | Echo | Fresh screenshots or clip | Reddit draft if useful, X/Bluesky |
| 3 | Jul 13-19 | Add the second-app thread | Routey | First public-safe proof asset | Umbrella post draft |
| 4 | Jul 20-26 | Show the app batch | MacroMark, NS Marks The Spot, Turn Timer | Devlogs plus screenshots/clips | GitHub/devlog, X/Bluesky |
| 5 | Jul 27-Aug 2 | Launch week prep | Active apps | Final shipped claims only | Launch copy bank |

## Draft Queue

| ID | Week | App | Format | Surface | Status | Proof link/asset | Draft owner |
|---|---|---|---|---|---|---|---|
| JUL-01 | 1 | Echo | Weekly build note | GitHub/devlog mirror | Ready to draft | `docs/guides/devlog.md` generated block | David |
| JUL-02 | 1 | Echo | Short proof thread | X/Bluesky/Mastodon | Draft needed | Latest devlog digest | David |
| JUL-03 | 2 | Echo | Problem/solution note | Reddit candidate | Hold for screenshot | Reader/narration/review clip | David |
| JUL-04 | 2 | Echo | Demo clip caption | X/Bluesky | Hold for clip | 20-40 second clip | David |
| JUL-05 | 3 | Routey | First public note | X/Bluesky or devlog | Blocked on proof | Routey URL/screenshot | David |
| JUL-06 | 3 | Umbrella | Monthly build ledger | GitHub/devlog | Draft needed | Echo + Routey proof points | David |
| JUL-07 | 4 | Echo | TestFlight/beta note | GitHub + optional social | Draft needed | TestFlight notes, beta guide | David |
| JUL-08 | 4 | MacroMark | Capture workflow note | Optional social | Hold for clip | Watch capture proof asset | David |
| JUL-09 | 4 | NS Marks The Spot | Map/history progress note | Optional social | Hold for screenshot | Current map proof asset | David |
| JUL-10 | 4 | Turn Timer | Rebrand progress note | Optional social | Hold for naming check | Current timer screenshot | David |
| JUL-11 | 5 | Echo | Launch-day copy bank | App/site/social | Draft needed | Final release notes | David |
| JUL-12 | 5 | Umbrella | What shipped this month | GitHub/devlog | Draft needed | Calendar recap | David |

## Week 1 Drafts

### JUL-01: Echo Weekly Build Note

Purpose: Point to the public proof ledger without asking for attention.

Skeleton:

```markdown
Echo's devlog now has an automated weekly digest at the top, generated from the
actual merged commits and kept separate from the hand-written narrative.

This week's digest covers: [top 2-3 shipped items].

Proof: [devlog link]
```

Review notes:

- Use only items from the generated block or merged release notes.
- Keep it factual; no launch promise unless the build is actually ready.

### JUL-02: Short Social Mirror

Purpose: One compact post for people who will never open the full devlog.

Skeleton:

```markdown
This week in Echo:

- [specific shipped item]
- [specific fix]
- [specific improvement]

The public devlog is generated from the repo history, so the story stays
auditable instead of becoming marketing fog: [link]
```

Review notes:

- Swap "this week" for exact dates if posting late.
- Avoid broad claims like "done" or "launching soon" unless they are true.

## Community Candidate Rules

Only make a Reddit/community post when all three are true:

1. The post teaches or shows something useful without requiring an install.
2. The community rules allow self-made project posts.
3. There is time to reply thoughtfully for at least 24 hours.

If any answer is no, keep the item as a devlog/social mirror instead.

## End-of-Month Recap Template

```markdown
# July Build Ledger

## Echo

- Shipped:
- Fixed:
- Learned:
- Still not shipped:

## Routey

- Shipped:
- Fixed:
- Learned:
- Still not shipped:

## MacroMark

- Shipped:
- Fixed:
- Learned:
- Still not shipped:

## NS Marks The Spot

- Shipped:
- Fixed:
- Learned:
- Still not shipped:

## Turn Timer

- Shipped:
- Fixed:
- Learned:
- Still not shipped:

## Next Month

- What gets public proof:
- What stays private:
- What needs a screenshot or clip:
```
