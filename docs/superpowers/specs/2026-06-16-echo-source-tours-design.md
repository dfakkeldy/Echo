# Echo Source Tours — Design Spec

- **Date:** 2026-06-16
- **Status:** Approved (brainstorming complete) — ready for implementation planning
- **Author:** Dan + Claude (brainstorming session)

## Goal

A small website that teaches iOS/macOS development by walking through **Echo's own
source code** as a set of curated, deeply-annotated "tours." Primary purpose is the
author's (Dan's) own understanding of his codebase; public usefulness is a welcome
bonus, not a design driver.

## Non-goals (YAGNI — explicitly out of scope)

- Not a beginner Swift curriculum. It assumes Swift/SwiftUI literacy.
- Not full-codebase coverage. The 464 Swift files are **not** all annotated — only
  hand-picked subsystems. Boilerplate (most of `EchoCore/Views`, asset catalogs,
  glue) is never toured.
- No live code-extraction pipeline, no CI coupling to Echo, no auto-regeneration.
- No comments, accounts, analytics, or interactive code execution.
- No directory-tree-of-the-whole-app front door (rejected during brainstorming as
  low-value for this goal).

## Locked decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Audience | Dan, primarily; public bonus | Reframes "tree-first" as fine; pedagogy-for-strangers concerns drop away |
| Scope | Curated tours only (~5–8) | Highest learning-per-hour; avoids annotating boilerplate |
| Authoring | Claude generates all annotations | Fastest path to a complete artifact; learning via reading |
| Sync model | Snapshot pinned to a commit SHA per tour | Tour = "lecture notes as of `sha`"; refresh on revisit; no maintenance pipeline |
| Tech stack | Astro Starlight → GitHub Pages | Free nav/search/highlighting/dark-mode/mobile; minimal JS for a Swift dev |
| Reading layout | Interleaved (prose → code block → prose → code block) | Matches "each block has an explanation"; native to Starlight markdown; mobile-perfect |
| Location | Separate repo (`echo-source-tours`) | Keeps Node/JS tooling out of the clean Swift repo; own Pages deploy |
| Build sequence | Scaffold + all first-batch tours in one pass | User opted for full first pass over slice-then-pause |

## Information architecture

- **Home** — short intro + a card grid of tours (title, one-line hook, difficulty,
  "as of `sha`" badge).
- **Tour page** (core unit) — each tour:
  1. Opens with a **mini file-tree** listing *only the files in this subsystem*
     (preserves the "see the structure" instinct, scoped to what's relevant).
  2. Followed by an **interleaved walkthrough**: prose, then a real fenced
     ```swift code block, then prose explaining the next block, top to bottom.
     Each block answers: what it does, why it's there, why it's needed.
- **Concepts glossary** (light, optional) — short entries for recurring ideas
  (`@Observable`, GRDB `DatabaseQueue`, dynamic time warping) that tours link to,
  so individual tours stay focused instead of re-explaining fundamentals.

## Content & sync model

- **One MDX file per tour.** Code lives in fenced `swift` blocks snapshotted from the
  real source at a known commit; prose lives between the blocks.
- Front-matter carries `sourceCommit:` (and a short human date). The site renders an
  **"as of `abc123`"** badge so staleness is explicit, never silent.
- **Refresh procedure:** when Dan revisits a subsystem, Claude re-reads the current
  source and regenerates that tour's MDX + bumps `sourceCommit`. No automation.
- **Honesty rule** (matches Echo's CLAUDE.md ethos): tours describe code as it *is*
  at the pinned commit; the SHA badge communicates "this may have since moved on."

## Tech stack & hosting

- **Astro Starlight** static site. Claude authors Markdown/MDX; Dan runs one build and
  deploys to **GitHub Pages** (Starlight has a documented Pages workflow).
- Separate repository, e.g. `echo-source-tours`. The spec and tour content are the only
  things that reference Echo; there is no build-time dependency on the Echo repo.

## Tours

### Full candidate menu (real Echo subsystems)

1. **DI without ceremony** — `DatabaseService` concrete-type + `inMemory:` testing; the
   "deleted the protocol theater" story. (`Shared/Database`, `EchoCore/Services`)
2. **On-device alignment pipeline** — VAD → WhisperKit → DTW.
   (`AutoAlignmentService`, `TokenDTW`, `ChapterTitleMatcher`)
3. **One model, four targets** — how `Shared/` feeds iOS/watch/macOS/Widget + parity
   discipline. (`Shared/`, `Echo Watch App`, `Echo macOS`, `Echo Widget`)
4. **GRDB migrations safely** — versioned migrations, data-loss avoidance.
   (`Shared/Database`, ~53 files)
5. **PlayerModel, decomposed** — taming a large `@Observable`. (`EchoCore/ViewModels`,
   `EchoCore/State`)
6. **EPUB → blocks parser** — a self-contained parsing problem.
   (`Shared/EPUBBlockParser`)
7. **Widget ↔ app data sharing** — app-group GRDB gotchas. (`Echo Widget`,
   `Shared/Database`)
8. **On-device narration (TTS)** — Kokoro/ANE. ⚠️ In active flux; will rot fast — defer
   until the engine stabilizes.

### First batch (this implementation)

- **Tour 1 — DI without ceremony** (built first as the format proof).
- **Tour 2 — On-device alignment pipeline.**
- **Tour 3 — One model, four targets.**

Tours 4–8 are future batches, each its own spec → plan → build cycle.

## Build sequence

1. Scaffold Astro Starlight: site config, theme, home page, glossary stub, GitHub
   Pages deploy workflow.
2. Author **Tour 1 (DI)** end-to-end as the canonical format example.
3. Author **Tour 2 (alignment)** and **Tour 3 (cross-platform)** following the same
   pattern.
4. Each tour: read the real source, snapshot the relevant blocks, write interleaved
   prose, stamp `sourceCommit`, build the mini file-tree.

## Success criteria

- Site builds locally and deploys to GitHub Pages with one documented command.
- Three tours render with interleaved layout, mini file-tree, and "as of `sha`" badge.
- A reader (Dan) can understand each subsystem from the tour alone, without opening
  Xcode.
- Every code block shown is faithfully copied from Echo at the stamped commit.
- Adding/refreshing a tour is a single self-contained MDX edit — no pipeline.

## Risks & mitigations

- **Annotation rot** — mitigated by per-tour SHA badge + "lecture notes" framing;
  refresh on revisit, not continuously.
- **Tour 8 (narration) churn** — explicitly deferred until the engine stabilizes.
- **Scope creep toward "annotate everything"** — guarded by the non-goals list; tours
  are added deliberately, one spec at a time.
- **Web-toolchain friction for a Swift dev** — mitigated by Starlight (content is
  markdown; build/deploy is one command).

## Open questions

None blocking. Repo name (`echo-source-tours` vs alternative) to be confirmed at
scaffold time.
