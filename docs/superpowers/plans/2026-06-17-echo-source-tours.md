# Echo Source Tours Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a separate Astro Starlight static site of three curated, annotated "tours" through the Echo codebase, deployable to GitHub Pages.

**Architecture:** A standalone Astro Starlight site in its own repo. Content is one MDX file per tour using an interleaved layout (prose → real code snapshot → prose). Each tour is "lecture notes" pinned to Echo commit `c5807ec`, shown via a `SourceCommit` badge. Internal-link correctness is enforced by `starlight-links-validator` at build time. No live coupling to the Echo repo — code is snapshotted by hand.

**Tech Stack:** Astro, Starlight, MDX, Expressive Code (bundled), `starlight-links-validator`, GitHub Pages (`withastro/action`), Node 26 / npm 11.

---

## Shared constants (used throughout)

| Name | Value |
|------|-------|
| `SITE` | `/Users/dfakkeldy/Developer/echo-source-tours` (new repo, sibling of Echo) |
| `ECHO_SRC` | `/Users/dfakkeldy/Developer/Echo/.claude/worktrees/hardcore-bouman-4b6eac` (read source here; subsystem files identical to `origin/main`) |
| `SOURCE_SHA` | `c5807ec` |
| `SOURCE_DATE` | `2026-06-17` |
| `ECHO_WEB` | `https://github.com/dfakkeldy/Echo` |
| commit link | `https://github.com/dfakkeldy/Echo/commit/c5807ec` |
| file link | `https://github.com/dfakkeldy/Echo/blob/c5807ec/<path>` |
| Pages base | `/echo-source-tours` |

**Authoring rule for all tours:** every line of Swift shown in a code block MUST be copied verbatim from the file under `ECHO_SRC`. After writing a tour, the fidelity check (a `grep -F` of a distinctive line against the source file) MUST pass. Do not paraphrase code.

**Link rule:** prefer Starlight components (`LinkCard`, hero `actions`) and relative markdown links (`../tours/...`). The links-validator runs on every `npm run build`; a task is not done until the build is green. If a link form is rejected, adjust it until the build passes — do not disable the validator.

---

### Task 1: Scaffold the Starlight site

**Files:**
- Create: entire `/Users/dfakkeldy/Developer/echo-source-tours/` tree (via scaffolder)

- [ ] **Step 1: Run the Starlight scaffolder non-interactively**

```bash
cd /Users/dfakkeldy/Developer
npm create astro@latest echo-source-tours -- \
  --template starlight --install --git --skip-houston --yes
```

Expected: creates `echo-source-tours/`, installs deps, makes an initial git commit.

- [ ] **Step 2: Verify the scaffold builds**

```bash
cd /Users/dfakkeldy/Developer/echo-source-tours
npm run build
```

Expected: `[build] Complete!` with no errors; a `dist/` directory is produced.

- [ ] **Step 3: Note the generated content-config location**

```bash
ls src/content.config.ts src/content/config.ts 2>/dev/null
```

Expected: one of them exists. Record which (used in Task 3). Current Starlight uses `src/content.config.ts`.

- [ ] **Step 4: Commit (only if the scaffolder left uncommitted changes)**

```bash
cd /Users/dfakkeldy/Developer/echo-source-tours
git add -A && git commit -m "chore: scaffold Astro Starlight site" || echo "nothing to commit"
```

---

### Task 2: Configure the site (title, sidebar, Pages base, code themes)

**Files:**
- Modify: `/Users/dfakkeldy/Developer/echo-source-tours/astro.config.mjs`

- [ ] **Step 1: Replace `astro.config.mjs` with the configured version**

```js
// astro.config.mjs
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

export default defineConfig({
  site: 'https://dfakkeldy.github.io',
  base: '/echo-source-tours',
  integrations: [
    starlight({
      title: 'Echo Source Tours',
      description: 'Learn iOS/macOS development by touring the Echo codebase.',
      social: [
        { icon: 'github', label: 'GitHub', href: 'https://github.com/dfakkeldy/Echo' },
      ],
      sidebar: [
        { label: 'Start here', items: [{ label: 'Welcome', slug: '' }] },
        { label: 'Tours', autogenerate: { directory: 'tours' } },
        { label: 'Concepts', autogenerate: { directory: 'concepts' } },
      ],
      expressiveCode: { themes: ['github-dark', 'github-light'] },
    }),
  ],
});
```

- [ ] **Step 2: Verify the build still succeeds**

```bash
cd /Users/dfakkeldy/Developer/echo-source-tours && npm run build
```

Expected: `[build] Complete!`. (Sidebar groups for `tours`/`concepts` may warn that the directories are empty — that is fine until Task 5+.)

- [ ] **Step 3: Commit**

```bash
git add astro.config.mjs && git commit -m "chore: configure site title, sidebar, and Pages base"
```

---

### Task 3: Add the `SourceCommit` badge component and extend the content schema

**Files:**
- Create: `/Users/dfakkeldy/Developer/echo-source-tours/src/components/SourceCommit.astro`
- Modify: the content config file recorded in Task 1 Step 3 (`src/content.config.ts`)

- [ ] **Step 1: Create the `SourceCommit.astro` component**

```astro
---
// src/components/SourceCommit.astro
interface Props {
  commit: string;   // short sha, e.g. "c5807ec"
  date: string;     // human date, e.g. "2026-06-17"
  repo?: string;    // GitHub web base
}
const { commit, date, repo = 'https://github.com/dfakkeldy/Echo' } = Astro.props;
const href = `${repo}/commit/${commit}`;
---
<p class="source-commit">
  📌 Source: <a href={href} target="_blank" rel="noopener">Echo @ <code>{commit}</code></a>
  · snapshot as of {date}. The code may have changed since.
</p>

<style>
  .source-commit {
    font-size: 0.85rem;
    background: var(--sl-color-gray-6);
    border: 1px solid var(--sl-color-gray-5);
    border-radius: 0.5rem;
    padding: 0.5rem 0.75rem;
    margin-block: 1rem;
  }
  .source-commit code { font-size: 0.9em; }
</style>
```

- [ ] **Step 2: Extend the docs schema with optional source fields**

Replace the content config file (`src/content.config.ts`) with:

```ts
// src/content.config.ts
import { defineCollection } from 'astro:content';
import { docsLoader } from '@astrojs/starlight/loaders';
import { docsSchema } from '@astrojs/starlight/schema';
import { z } from 'astro:schema';

export const collections = {
  docs: defineCollection({
    loader: docsLoader(),
    schema: docsSchema({
      extend: z.object({
        sourceCommit: z.string().optional(),
        sourceDate: z.string().optional(),
      }),
    }),
  }),
};
```

If the scaffolder generated `src/content/config.ts` instead (older layout), apply the same `extend` to that file and keep its existing import paths.

- [ ] **Step 3: Verify the build still succeeds**

```bash
cd /Users/dfakkeldy/Developer/echo-source-tours && npm run build
```

Expected: `[build] Complete!`.

- [ ] **Step 4: Commit**

```bash
git add src/components/SourceCommit.astro src/content.config.ts && \
  git commit -m "feat: add SourceCommit badge and sourceCommit/sourceDate schema fields"
```

---

### Task 4: Install the internal-link validator (the build-time test harness)

**Files:**
- Modify: `/Users/dfakkeldy/Developer/echo-source-tours/astro.config.mjs`
- Modify: `package.json` (dependency added by npm)

- [ ] **Step 1: Install the plugin**

```bash
cd /Users/dfakkeldy/Developer/echo-source-tours
npm install starlight-links-validator
```

- [ ] **Step 2: Register the plugin in `astro.config.mjs`**

Add the import at the top:

```js
import starlightLinksValidator from 'starlight-links-validator';
```

Add a `plugins` entry inside the `starlight({ ... })` options (alongside `title`, `sidebar`, etc.):

```js
      plugins: [starlightLinksValidator()],
```

- [ ] **Step 3: Verify the build runs the validator and passes**

```bash
npm run build
```

Expected: build completes; output mentions link checking with no broken links (there is no cross-linked content yet).

- [ ] **Step 4: Prove the harness actually fails on a bad link**

Temporarily append a broken link to `src/content/docs/index.mdx`:

```mdx
[broken](/echo-source-tours/tours/does-not-exist/)
```

```bash
npm run build
```

Expected: build FAILS with a broken-link error from starlight-links-validator. Then remove the line and re-run `npm run build`; expected PASS.

- [ ] **Step 5: Commit**

```bash
git add astro.config.mjs package.json package-lock.json && \
  git commit -m "test: enforce internal links with starlight-links-validator"
```

---

### Task 5: Home page and concepts glossary stub

**Files:**
- Modify: `/Users/dfakkeldy/Developer/echo-source-tours/src/content/docs/index.mdx`
- Create: `/Users/dfakkeldy/Developer/echo-source-tours/src/content/docs/concepts/index.md`

- [ ] **Step 1: Write the home page with a tour card grid**

Replace `src/content/docs/index.mdx` with:

```mdx
---
title: Echo Source Tours
description: Learn iOS & macOS development by touring a real, shipping app.
template: splash
hero:
  tagline: Learn iOS by reading a real, shipping app — Echo — one subsystem at a time.
  actions:
    - text: Start with Dependency Injection
      link: /echo-source-tours/tours/di-without-ceremony/
      icon: right-arrow
---

import { CardGrid, LinkCard } from '@astrojs/starlight/components';

These tours walk through real subsystems of **Echo**, an open-source audiobook study
player for iOS, watchOS, and macOS. Each tour snapshots the actual source at a known
commit and explains it block by block.

## Tours

<CardGrid>
  <LinkCard
    title="DI without ceremony"
    href="/echo-source-tours/tours/di-without-ceremony/"
    description="How Echo injects its database with a concrete type and two initializers — no protocols, no mocks."
  />
  <LinkCard
    title="On-device alignment pipeline"
    href="/echo-source-tours/tours/alignment-pipeline/"
    description="Matching audiobook audio to ebook text on-device: silence chunking, WhisperKit, and dynamic time warping."
  />
  <LinkCard
    title="One model, four targets"
    href="/echo-source-tours/tours/one-model-four-targets/"
    description="How the Shared/ layer feeds iOS, watchOS, the widget, and macOS from one source of truth."
  />
</CardGrid>
```

- [ ] **Step 2: Create the concepts glossary stub**

```md
---
title: Concepts
description: Short explanations of recurring ideas the tours link to.
---

Short, focused explanations of ideas that come up across tours. Entries are added as
tours reference them — this page is intentionally small.

(No entries yet. The first tours will add `@Observable`, GRDB `DatabaseQueue`, and
dynamic time warping here as they reference them.)
```

- [ ] **Step 3: Verify the build and links pass**

```bash
cd /Users/dfakkeldy/Developer/echo-source-tours && npm run build
```

Expected: `[build] Complete!` with links-validator green. (The three tour links do not exist yet; if the validator flags them, that is expected — proceed to create tours in Tasks 6–8 and re-run. To keep this task self-contained and green, comment out the two not-yet-built `LinkCard`s and the hero `actions` for tours that do not yet exist, then restore each as its tour lands. The DI tour link is restored in Task 6, alignment in Task 7, cross-platform in Task 8.)

- [ ] **Step 4: Commit**

```bash
git add src/content/docs/index.mdx src/content/docs/concepts/index.md && \
  git commit -m "feat: add home page tour grid and concepts glossary stub"
```

---

### Task 6: Tour 1 — DI without ceremony (canonical format example)

**Files:**
- Read (source): `ECHO_SRC/Shared/Database/DatabaseService.swift` (124 lines), and skim `ECHO_SRC/Shared/Database/Schema_V1.swift` for the migrator pattern
- Create: `/Users/dfakkeldy/Developer/echo-source-tours/src/content/docs/tours/di-without-ceremony.mdx`

- [ ] **Step 1: Read the source and pick the blocks to snapshot**

```bash
sed -n '1,124p' /Users/dfakkeldy/Developer/Echo/.claude/worktrees/hardcore-bouman-4b6eac/Shared/Database/DatabaseService.swift
```

Identify these exact regions to copy verbatim into blocks:
1. The class declaration + the stored `DatabaseQueue` property.
2. The production initializer (file-backed `DatabaseQueue`).
3. The `inMemory:` initializer used by tests.
4. The `DatabaseMigrator` / `registerMigration` setup.
5. One representative read or write using GRDB (a parameterized/safe query).

- [ ] **Step 2: Write the tour MDX (interleaved layout)**

Create `src/content/docs/tours/di-without-ceremony.mdx` using this exact skeleton; replace each `// PASTE: ...` with the verbatim block from Step 1 and write 2–4 sentences of prose under each (what it does · why it's there · why it's needed):

````mdx
---
title: DI without ceremony
description: How Echo injects its database with a concrete type and two initializers.
sourceCommit: c5807ec
sourceDate: 2026-06-17
sidebar:
  order: 1
---

import { FileTree, Aside } from '@astrojs/starlight/components';
import SourceCommit from '../../../components/SourceCommit.astro';

<SourceCommit commit="c5807ec" date="2026-06-17" />

Echo never hides its database behind a protocol. It injects a **concrete type** and
makes it testable with a second initializer. This tour shows how, and why the team
deleted an earlier "protocol-oriented" abstraction that was never used as a real seam.

## The files in this tour

<FileTree>
- Shared/Database
  - DatabaseService.swift
  - Schema_V1.swift
</FileTree>

## A concrete type, not a protocol

```swift title="Shared/Database/DatabaseService.swift"
// PASTE: class declaration + stored DatabaseQueue property
```

(prose: what this type is, why concrete-over-protocol, link to the [DatabaseQueue concept](../../concepts/))

## Two initializers: production vs. tests

```swift title="Shared/Database/DatabaseService.swift"
// PASTE: production init()
```

(prose: opens a file-backed queue at the app-group path; runs migrations)

```swift title="Shared/Database/DatabaseService.swift"
// PASTE: init(inMemory:)
```

(prose: throwaway in-memory DB with the SAME schema — this is the test seam, no mocks)

<Aside type="tip">
This is the whole DI strategy: a second `init`. Tests construct
`DatabaseService(inMemory: true)` and get a real database with real migrations.
</Aside>

## Migrations as the schema source of truth

```swift title="Shared/Database/DatabaseService.swift"
// PASTE: DatabaseMigrator / registerMigration setup
```

(prose: both inits run the same migrator, so tests exercise the real schema)

## A safe query

```swift title="Shared/Database/DatabaseService.swift"
// PASTE: one representative parameterized read/write
```

(prose: parameterized query, runs off the main thread, why that matters)

## Why it's built this way

(prose wrap-up: the deleted-protocol-theater lesson — an abstraction with one
implementation and no wired-in test double is just indirection. Add a protocol only
when a real second implementation or a genuinely wired test double exists.)
````

- [ ] **Step 3: Restore the DI link on the home page**

If the DI `LinkCard`/hero action was commented out in Task 5 Step 3, uncomment it now.

- [ ] **Step 4: Verify build + links**

```bash
cd /Users/dfakkeldy/Developer/echo-source-tours && npm run build
```

Expected: `[build] Complete!`, links-validator green.

- [ ] **Step 5: Fidelity check — every block is real code**

For each pasted block, pick one distinctive line and confirm it exists in the source:

```bash
grep -F 'inMemory' /Users/dfakkeldy/Developer/Echo/.claude/worktrees/hardcore-bouman-4b6eac/Shared/Database/DatabaseService.swift
```

Expected: a match. Repeat with a distinctive line from each other block. Any non-match means the code was paraphrased — fix it to match the source exactly.

- [ ] **Step 6: Commit**

```bash
git add src/content/docs/tours/di-without-ceremony.mdx src/content/docs/index.mdx && \
  git commit -m "feat: add Tour 1 — DI without ceremony"
```

---

### Task 7: Tour 2 — On-device alignment pipeline

**Files:**
- Read (source): `ECHO_SRC/EchoCore/Services/ChapterTitleMatcher.swift`, `ECHO_SRC/EchoCore/Services/TokenDTW.swift` (330 lines), `ECHO_SRC/EchoCore/Services/AutoAlignmentService.swift` (637 lines — excerpt only), and note `ECHO_SRC/EchoTests/TokenDTWTests.swift` exists
- Create: `/Users/dfakkeldy/Developer/echo-source-tours/src/content/docs/tours/alignment-pipeline.mdx`

- [ ] **Step 1: Read the sources and choose excerpts**

```bash
sed -n '1,120p' /Users/dfakkeldy/Developer/Echo/.claude/worktrees/hardcore-bouman-4b6eac/EchoCore/Services/ChapterTitleMatcher.swift
sed -n '1,120p' /Users/dfakkeldy/Developer/Echo/.claude/worktrees/hardcore-bouman-4b6eac/EchoCore/Services/TokenDTW.swift
grep -n 'func ' /Users/dfakkeldy/Developer/Echo/.claude/worktrees/hardcore-bouman-4b6eac/EchoCore/Services/AutoAlignmentService.swift
```

Choose these excerpts (these files are large — excerpt key functions, never paste whole files):
1. ChapterTitleMatcher: the fuzzy match (Levenshtein + word-level Jaccard) and the generic-numeric-title veto.
2. AutoAlignmentService: the top-level pipeline sequence — Tier 0 title match, then VAD/silence chunking → WhisperKit transcription → DTW match → anchor insertion; and the line that clears previous auto anchors before a run.
3. TokenDTW: the core dynamic-programming matrix loop.

- [ ] **Step 2: Write the tour MDX**

Create `src/content/docs/tours/alignment-pipeline.mdx` using this exact skeleton; replace each `// PASTE: ...` with a verbatim excerpt and write prose under each:

````mdx
---
title: On-device alignment pipeline
description: Matching audiobook audio to ebook text on-device with VAD, WhisperKit, and DTW.
sourceCommit: c5807ec
sourceDate: 2026-06-17
sidebar:
  order: 2
---

import { FileTree, Aside } from '@astrojs/starlight/components';
import SourceCommit from '../../../components/SourceCommit.astro';

<SourceCommit commit="c5807ec" date="2026-06-17" />

Echo aligns an audiobook to its ebook entirely on-device. This tour follows the
progressive pipeline: cheap chapter-title matching first, then content alignment via
on-device transcription and dynamic time warping.

## The files in this tour

<FileTree>
- EchoCore/Services
  - AutoAlignmentService.swift
  - ChapterTitleMatcher.swift
  - TokenDTW.swift
</FileTree>

## Tier 0: match chapter titles before transcribing anything

```swift title="EchoCore/Services/ChapterTitleMatcher.swift"
// PASTE: Levenshtein + Jaccard fuzzy match
```

(prose: cheapest signal first; why generic numeric labels like "Chapter 7" are skipped/vetoed)

## The pipeline, end to end

```swift title="EchoCore/Services/AutoAlignmentService.swift"
// PASTE: the orchestration sequence (chunk → transcribe → DTW → insert anchors)
```

(prose: each stage; why anchors from the previous run are cleared so re-alignment converges)

## Dynamic time warping the tokens

```swift title="EchoCore/Services/TokenDTW.swift"
// PASTE: the core DP matrix loop
```

(prose: what DTW is doing here, link to the [dynamic time warping concept](../../concepts/))

<Aside type="note">
This logic is unit-tested — see `TokenDTWTests` and `ChapterTitleMatcherTests` in the
Echo repo. Algorithmic code like this is exactly what benefits from tests.
</Aside>

## Why it's built this way

(prose wrap-up: progressive/tiered design — do the cheap, high-confidence work first
and only fall back to expensive on-device transcription when needed)
````

- [ ] **Step 3: Add the "dynamic time warping" glossary entry it links to**

Append to `src/content/docs/concepts/index.md`:

```md

## Dynamic time warping (DTW)

An algorithm for aligning two sequences that run at different speeds — here, ebook
tokens against transcribed-audio tokens. It finds the lowest-cost path through a
match-cost matrix, allowing stretches and compressions so spoken pacing can differ
from the written text.
```

- [ ] **Step 4: Restore the alignment link on the home page (if commented in Task 5)**

- [ ] **Step 5: Verify build + links**

```bash
cd /Users/dfakkeldy/Developer/echo-source-tours && npm run build
```

Expected: `[build] Complete!`, links-validator green.

- [ ] **Step 6: Fidelity check**

```bash
grep -F 'Jaccard' /Users/dfakkeldy/Developer/Echo/.claude/worktrees/hardcore-bouman-4b6eac/EchoCore/Services/ChapterTitleMatcher.swift || \
grep -nF 'jaccard' /Users/dfakkeldy/Developer/Echo/.claude/worktrees/hardcore-bouman-4b6eac/EchoCore/Services/ChapterTitleMatcher.swift
```

Expected: a match (case may vary — confirm the real identifier). Repeat with a distinctive line from each pasted excerpt against its source file.

- [ ] **Step 7: Commit**

```bash
git add src/content/docs/tours/alignment-pipeline.mdx src/content/docs/concepts/index.md src/content/docs/index.mdx && \
  git commit -m "feat: add Tour 2 — on-device alignment pipeline"
```

---

### Task 8: Tour 3 — One model, four targets

**Files:**
- Read (source): `ECHO_SRC/Shared/AppGroupDefaults.swift`, `ECHO_SRC/Shared/FileLocations.swift`, `ECHO_SRC/Shared/WatchAction.swift`, `ECHO_SRC/Shared/WatchMessageKey.swift`, `ECHO_SRC/Echo Widget/Views/Echo_Widget.swift`, `ECHO_SRC/Echo Widget/Models/AppIntent.swift`
- Create: `/Users/dfakkeldy/Developer/echo-source-tours/src/content/docs/tours/one-model-four-targets.mdx`

- [ ] **Step 1: Read the sources and choose excerpts**

```bash
cd /Users/dfakkeldy/Developer/Echo/.claude/worktrees/hardcore-bouman-4b6eac
sed -n '1,80p' Shared/AppGroupDefaults.swift
sed -n '1,80p' Shared/FileLocations.swift
sed -n '1,80p' Shared/WatchAction.swift
sed -n '1,60p' Shared/WatchMessageKey.swift
sed -n '1,80p' "Echo Widget/Views/Echo_Widget.swift"
```

Scope this tour to ONE concrete narrative (not a survey): **`Shared/` is the single
source of truth that every target consumes.** Choose excerpts that show:
1. The app-group identifier / shared container (`AppGroupDefaults`, `FileLocations`) — the path the iOS app AND the widget both open.
2. The widget reading that shared data (`Echo_Widget` / `AppIntent`).
3. The iOS↔watch contract (`WatchAction` / `WatchMessageKey`) shared by app and watch.

- [ ] **Step 2: Write the tour MDX**

Create `src/content/docs/tours/one-model-four-targets.mdx` using this exact skeleton; replace each `// PASTE: ...` with a verbatim excerpt and write prose under each:

````mdx
---
title: One model, four targets
description: How the Shared/ layer feeds iOS, watchOS, the widget, and macOS.
sourceCommit: c5807ec
sourceDate: 2026-06-17
sidebar:
  order: 3
---

import { FileTree, Aside } from '@astrojs/starlight/components';
import SourceCommit from '../../../components/SourceCommit.astro';

<SourceCommit commit="c5807ec" date="2026-06-17" />

Echo ships iOS, watchOS, macOS, and a widget. They stay consistent because the real
contracts live in one place — `Shared/` — and every target imports the same types.
This tour follows two of those shared contracts to their consumers.

## The files in this tour

<FileTree>
- Shared
  - AppGroupDefaults.swift
  - FileLocations.swift
  - WatchAction.swift
  - WatchMessageKey.swift
- Echo Widget
  - Views/Echo_Widget.swift
  - Models/AppIntent.swift
</FileTree>

## One database location, shared by app and widget

```swift title="Shared/AppGroupDefaults.swift"
// PASTE: the app-group identifier / shared container
```

(prose: why an app group; both processes resolve the same on-disk path)

```swift title="Shared/Echo_Widget.swift"
// PASTE: the widget reading the shared data
```

(prose: the widget is a separate process but reads the same source of truth)

## One message contract, shared by app and watch

```swift title="Shared/WatchAction.swift"
// PASTE: the WatchAction contract
```

(prose: a single enum/keys file both sides import means messages can't drift)

<Aside type="tip">
The lesson: put the *contract* in `Shared/`, not the *behavior*. Each target keeps its
own UI, but they agree on data shapes and keys because there's exactly one definition.
</Aside>

## Why it's built this way

(prose wrap-up: a single shared definition is what makes cross-target parity tractable;
duplicating these types per target is how watch/widget silently drift from iOS)
````

- [ ] **Step 3: Restore the cross-platform link on the home page (if commented in Task 5)**

- [ ] **Step 4: Verify build + links**

```bash
cd /Users/dfakkeldy/Developer/echo-source-tours && npm run build
```

Expected: `[build] Complete!`, links-validator green.

- [ ] **Step 5: Fidelity check**

```bash
grep -rnF 'group.' /Users/dfakkeldy/Developer/Echo/.claude/worktrees/hardcore-bouman-4b6eac/Shared/AppGroupDefaults.swift
```

Expected: the app-group identifier line matches what you pasted. Repeat with a distinctive line from each pasted excerpt against its source file.

- [ ] **Step 6: Commit**

```bash
git add src/content/docs/tours/one-model-four-targets.mdx src/content/docs/index.mdx && \
  git commit -m "feat: add Tour 3 — one model, four targets"
```

---

### Task 9: GitHub Pages deploy workflow, README, and final verification

**Files:**
- Create: `/Users/dfakkeldy/Developer/echo-source-tours/.github/workflows/deploy.yml`
- Create: `/Users/dfakkeldy/Developer/echo-source-tours/README.md`
- Create: `/Users/dfakkeldy/Developer/echo-source-tours/docs/design-spec.md` (copy of the brainstorming spec)

- [ ] **Step 1: Add the Pages deploy workflow**

```yaml
# .github/workflows/deploy.yml
name: Deploy to GitHub Pages
on:
  push:
    branches: [main]
  workflow_dispatch:
permissions:
  contents: read
  pages: write
  id-token: write
concurrency:
  group: pages
  cancel-in-progress: false
jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: withastro/action@v3
  deploy:
    needs: build
    runs-on: ubuntu-latest
    environment:
      name: github-pages
      url: ${{ steps.deployment.outputs.page_url }}
    steps:
      - id: deployment
        uses: actions/deploy-pages@v4
```

- [ ] **Step 2: Write the README (build, deploy, and tour-refresh instructions)**

```md
# Echo Source Tours

Curated, annotated walkthroughs of the [Echo](https://github.com/dfakkeldy/Echo)
codebase. Each tour is "lecture notes" snapshotted from a specific Echo commit.

## Develop

```bash
npm install
npm run dev      # local preview
npm run build    # production build + internal-link validation
```

## Deploy

Pushing to `main` triggers `.github/workflows/deploy.yml`, which builds and publishes to
GitHub Pages. One-time setup: create the GitHub repo, push, then enable
**Settings → Pages → Source: GitHub Actions**.

## Refreshing a tour

Tours are pinned to an Echo commit via `sourceCommit` in each MDX file's front-matter.
When the underlying subsystem changes, re-read the source at the new commit, update the
code blocks and prose, and bump `sourceCommit` / `sourceDate`. There is no automated
pipeline — this is intentional.
```

- [ ] **Step 3: Copy the design spec into the new repo**

```bash
mkdir -p /Users/dfakkeldy/Developer/echo-source-tours/docs
cp "/Users/dfakkeldy/Developer/Echo/.claude/worktrees/hardcore-bouman-4b6eac/docs/superpowers/specs/2026-06-16-echo-source-tours-design.md" \
   /Users/dfakkeldy/Developer/echo-source-tours/docs/design-spec.md
```

- [ ] **Step 4: Final full build**

```bash
cd /Users/dfakkeldy/Developer/echo-source-tours && npm run build
```

Expected: `[build] Complete!`, links-validator green, all three tours present in `dist/`.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/deploy.yml README.md docs/design-spec.md && \
  git commit -m "chore: add Pages deploy workflow, README, and design spec"
```

- [ ] **Step 6: Hand-off note (manual, by Dan — not automated)**

Creating the GitHub remote and enabling Pages requires Dan's account and is **not** done
by the executor:

```bash
# Dan runs, when ready:
cd /Users/dfakkeldy/Developer/echo-source-tours
gh repo create echo-source-tours --public --source . --push
# then: Settings → Pages → Source: GitHub Actions
```

Live URL will be `https://dfakkeldy.github.io/echo-source-tours`.

---

## Self-review (completed by plan author)

**Spec coverage:**
- Curated tours only → Tasks 6–8 (three tours), boilerplate untouched. ✓
- Claude generates all annotations → content authored in Tasks 6–8. ✓
- Snapshot pinned to SHA → `SourceCommit` component (Task 3) + front-matter + badge, SHA `c5807ec`. ✓
- Astro Starlight → Task 1. ✓
- Interleaved layout → MDX skeletons in Tasks 6–8 (prose/code/prose). ✓
- Mini file-tree per tour → `<FileTree>` in every tour. ✓
- Concepts glossary → Task 5 stub, populated in Task 7. ✓
- "As of sha" badge → `SourceCommit` rendered atop each tour. ✓
- Separate repo + GitHub Pages → Task 1 (own repo) + Task 9 (workflow). ✓
- First batch = DI, alignment, cross-platform → Tasks 6, 7, 8. ✓
- Honesty/staleness explicit → badge copy "may have changed since". ✓
- No live extraction pipeline → README states refresh is manual. ✓
- Tour 8 (narration) deferred → not in this plan (correct). ✓

**Placeholder scan:** The `// PASTE:` markers are deliberate, scoped authoring instructions tied to exact source files + a fidelity grep gate, not vague TODOs. Every config/component/workflow step contains complete code. ✓

**Type/name consistency:** Component is `SourceCommit` everywhere; props `commit`/`date` match between definition (Task 3) and usage (Tasks 6–8); schema fields `sourceCommit`/`sourceDate` match front-matter; base `/echo-source-tours` consistent across config, links, README, deploy. ✓
