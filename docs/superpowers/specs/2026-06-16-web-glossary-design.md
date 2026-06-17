# Web Glossary — Design

**Date:** 2026-06-16
**Status:** Approved design, pending implementation plan
**Surface:** The GitHub Pages site (`docs/`), not the README.

## Problem

Echo's `README.md` and website carry dense jargon across three flavours — technical/architecture
(WhisperKit, TokenDTW, GRDB), learning science (spaced repetition, context-dependent memory), and
formats/domain (EPUB, M4B, alignment drift). A layperson — and even the project's own author — can't
follow much of it. We want jargon to be **hover- (or tap-) to-define**, wiki-style, with full entries
a click away.

### Why the website, not the README

GitHub's Markdown pipeline strips inline HTML and CSS, so real hover popovers are impossible in
`README.md`. The site (`docs/*.html` + `styles.css`, served via GitHub Pages, `.nojekyll`, **zero JS,
no build step**) is plain HTML we fully control. The README links *out* to the web glossary.

## Decisions (locked)

| Question | Decision |
|---|---|
| Surface | Website, true hover popovers |
| Term scope | All three categories: Technical, Learning science, Formats & domain |
| Implementation | **Approach A** — tiny JS engine with a single source of truth |
| Seed size | Full set (~30 terms) in the first pass |
| Markup reach | Glossary page + README out-links + inline markup on `learn.html` and `manual.html` |
| "Runs no scripts" footer vow | Keep A; **reword the footer fineprint honestly** on every page (script is first-party, no cookies, no network) |

### The footer promise

Every page footer currently reads *"…hosts its own fonts, runs no scripts, and sets no cookies."*
Approach A adds a first-party `glossary.js`, so that clause must change to stay true. New wording
(applied to all `docs/*.html`): *"…hosts its own fonts, runs one small first-party script (the
glossary), sets no cookies, and makes no network calls."* This preserves the promise's real meaning —
no tracking, no third parties, no cookies — while being literally accurate.

Rejected alternatives: **B** (native Popover API) — tap-only, uneven Safari anchor-positioning,
definitions duplicated inline per page; **C** (pure-CSS `:hover`) — weak on touch, edge-clipping,
duplicated definitions, weakest a11y. Both fail the "single source of truth + works on touch +
accessibility-first" bar.

## Architecture

A definition is authored **once**, in `glossary.js`, and consumed in **two** places: the glossary
page renders from it, and the popover engine reads from it to enhance inline terms. Nothing is typed
twice, so nothing can drift.

```
docs/glossary.js   ──(single source of truth)──┐
                                               ├─→ glossary.html  (renders all entries, grouped)
                                               └─→ glossary engine (upgrades <a class="gloss"> inline)
```

### Components

**`docs/glossary.js`** — the data + the engine, one file, dependency-free, loaded with `defer`.
- `GLOSSARY` — an array of entries:
  ```js
  { slug: "whisperkit",
    term: "WhisperKit",
    category: "Technical",                       // "Technical" | "Learning science" | "Formats & domain"
    short: "Apple-silicon speech-to-text that runs entirely on your device.",   // ≤ ~140 chars, popover
    long:  "An on-device speech recognition engine … no audio ever leaves your phone.", // glossary page
    aliases: ["whisper"]                          // optional, future-proofing for matching
  }
  ```
- Engine behaviour (on `DOMContentLoaded`):
  1. Build a `slug → entry` map.
  2. For each `a.gloss[data-term]`: if the slug is unknown, **leave it as a plain link** (graceful);
     otherwise wire up the popover.
  3. One reusable popover element appended to `<body>`, repositioned per trigger (cheaper than one per term).
  4. **Open** on `mouseenter` / `focus` (desktop) and on `click`/tap (touch, `preventDefault` the nav).
     **Close** on `mouseleave` / `blur` / `Escape` / outside-tap / the popover's × button.
  5. Popover content = `short` def + a "Read full entry →" link to `glossary.html#slug`.
  6. **Edge-aware**: measure viewport; flip above/left when near an edge.

**`docs/glossary.html`** — new page, standard site chrome (header, nav, footer copied from a sibling
page such as `learn.html`). Uses the existing `.docs-layout` + `.docs-toc` pattern. The render logic
lives in `glossary.js` as an exported `renderGlossary(mountEl)` function; `glossary.html` contains an
empty `<div id="glossary-root">` and the page calls `renderGlossary` once the script loads. It iterates
`GLOSSARY`, groups by `category`, and emits one section per category with `<h3 id="{slug}">{term}</h3>`
+ `long` def, plus a category TOC. Keeping render in `glossary.js` means the page markup stays trivial
and the data/render logic stay co-located with the engine. If JS fails, `#glossary-root` shows a static
fallback note ("enable JavaScript to view definitions, or read the source in `glossary.js`") — acceptable,
this is a reference page, not core app function.

**`docs/styles.css`** (append-only block):
- `.gloss` — inline term: dotted underline in `--accent-gold`, normal text colour, pointer cursor;
  visible focus ring (reuse the site's gold `outline`).
- `.gloss-popover` — card: `background: var(--bg-raised)`, `1px solid var(--accent-gold)`,
  `color: var(--text-primary)`, rounded, drop shadow, max-width ~320px, small `short`-def text +
  a `--link`-coloured "Read full entry →". `z-index` above content.
- `@media (prefers-reduced-motion: reduce)` — disable the fade/scale transition.

**Inline term markup** (authored by hand on `learn.html`, `manual.html`, and in README out-links):
```html
<a class="gloss" href="glossary.html#whisperkit" data-term="whisperkit">WhisperKit</a>
```
Only the **first meaningful mention per section** is marked up, to avoid a field of dotted underlines.

### README integration

The README cannot pop. It instead:
- Links its hardest terms to `glossary.html#slug` (plain click-to-jump for repo browsers).
- Adds one pointer line near the top of the technical sections (Overview / Architecture):
  *"New to a term? Hover it on the [web glossary](https://dfakkeldy.github.io/Echo/glossary.html)."*
- Adds a Glossary row to the Documentation table.

## Data flow

1. Author writes a definition once in `glossary.js`.
2. `glossary.html` renders the canonical, anchored entry from it.
3. On any page that includes `glossary.js`, every `a.gloss[data-term]` is enhanced into a popover that
   reads the same `short` def; its "full entry" link points back to the glossary anchor.
4. Reader hovers/taps/focuses → peek; activates the link → full entry.

## Accessibility (non-negotiable for this project)

- Triggers are input-agnostic: hover **and** keyboard focus **and** touch.
- Popover dismissible via `Escape`, outside-tap, and a visible × ; focus is never trapped.
- The term is a real link, so screen readers always announce a navigable target; the short def is
  associated via `aria-describedby` on hover/focus, and the popover region is labelled for touch.
- Inherits Lexend / OpenDyslexic and the site's contrast tokens; honours `prefers-reduced-motion`.
- No-JS / unknown-slug fallback is always a working link — never a dead word.

## Seed terms (~30, first pass)

**Technical:** WhisperKit · CoreML · TokenDTW / Dynamic Time Warping · VAD (voice-activity detection) ·
Levenshtein distance · Jaccard similarity · GRDB · schema migration (`Schema_Vxx`) · security-scoped
bookmark · Keychain · `@Observable` · closure / dependency injection · WatchConnectivity (WCSession) ·
App Group · Accelerate.

**Learning science:** spaced repetition (SRS) · SM-2 algorithm · context-dependent memory ·
the testing effect · cognitive offloading · dual coding · retrieval cue · interleaving.

**Formats & domain:** EPUB · M4B · OPF spine · XHTML · audio↔text alignment · alignment anchor ·
drift / drift repair · continuous alignment · chapter atom (Libation-style sub-section) · pitch-corrected
speed.

(Exact final list and the wording of each `short`/`long` is settled during implementation; this is the
target coverage.)

## Out of scope (YAGNI)

- Glossary search box (category TOC suffices for ~30 terms).
- Any build step or term auto-extraction from prose.
- README popovers (technically impossible).
- Marking up `index.html` / `focus.html` / `devlog.html` this pass (addable later — the engine already
  works on any page that includes the script).

## Verification

No site test harness exists. Verify in-browser via the preview tools:
1. Load `glossary.html` — console clean, all categories render, anchors resolve.
2. Trigger a popover on `learn.html` (hover + keyboard focus) — correct `short` def, "full entry" link works.
3. Resize to a mobile viewport — tap opens, outside-tap and × close.
4. Confirm a term with JS disabled still navigates to its glossary anchor.

## Docs sync

This adds a website page + nav entry. Per `CLAUDE.md`, update `README.md`'s Documentation table to
list the Glossary; no `ARCHITECTURE.md` change needed (this is site content, not app architecture).
