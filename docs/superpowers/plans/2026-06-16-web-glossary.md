# Web Glossary Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a hover/tap/keyboard "what does this word mean?" glossary to the Echo website, with one canonical glossary page and inline popovers on `learn.html` + `manual.html`, driven by a single source of truth.

**Architecture:** One dependency-free file, `docs/glossary.js`, holds both the definitions (a `GLOSSARY` array) and the behaviour (a glossary-page renderer + an inline-popover engine). Any `<a class="gloss" data-term="slug">` on a page is *upgraded* into an accessible popover that reads the same definition the glossary page shows — so the two can never drift. Each term is authored as a real link, so with JS off it still navigates to the full entry.

**Tech Stack:** Static HTML + CSS (existing `docs/` GitHub Pages site, `.nojekyll`, no build step), one new ~120-line vanilla JS file. No frameworks, no dependencies.

**Reference spec:** `docs/superpowers/specs/2026-06-16-web-glossary-design.md`

---

## Context for the implementer (read before starting)

- The site lives in `docs/`. Pages are hand-written HTML sharing `docs/styles.css`. There is **no build step and no test runner** — verification is done in a browser.
- The site currently ships **zero JavaScript**. Every page footer says *"…runs no scripts, and sets no cookies."* This plan adds one first-party script, so **Task 7 rewords that footer line on every page** to stay truthful. Do not skip it.
- CSS uses custom properties already defined in `:root`: `--bg-color`, `--bg-raised`, `--text-primary`, `--text-secondary`, `--accent-gold`, `--accent-gold-soft`, `--accent-silver`, `--link`, `--glass-border`, `--glass-bg`, `--max-prose`. Reuse them — do not introduce new colors.
- Focus styling already exists site-wide: `a:focus-visible { outline: 3px solid var(--accent-gold); }`. Inline terms are `<a>`, so they inherit it for free.
- **Verification harness (used by several tasks):** serve the static site locally and drive it with the preview browser tools.
  - Start once: `python3 -m http.server 8123 --directory docs` (run in background).
  - Open pages with the preview tools at `http://localhost:8123/<page>.html` (`preview_start` / `preview_navigate`), then use `preview_console_logs`, `preview_snapshot`, `preview_click`, `preview_resize`.
  - Stop the server when finished.
- Commit after every task. Conventional Commits.

## File Structure

| File | Responsibility | Action |
|---|---|---|
| `docs/glossary.js` | Single source of truth: `GLOSSARY` data + `renderGlossary()` + inline popover engine | Create (Tasks 1–4) |
| `docs/styles.css` | Append `.gloss` term style, `.gloss-popover` card, glossary-page styles | Modify (Task 5) |
| `docs/glossary.html` | Canonical glossary page (site chrome + static category TOC + `#glossary-root`) | Create (Task 6) |
| `docs/learn.html` | Inline `.gloss` markup on 6 first-mention terms | Modify (Task 8) |
| `docs/manual.html` | Inline `.gloss` markup on 4 first-mention terms | Modify (Task 9) |
| All 8 `docs/*.html` | Add "Glossary" nav link, footer link, `<script defer>`, reworded fineprint | Modify (Task 7) |
| `README.md` | Glossary table row, pointer line, a few out-links | Modify (Task 10) |

---

## Task 1: Glossary data (`GLOSSARY` array)

Create the data half of the single source of truth. No behaviour yet.

**Files:**
- Create: `docs/glossary.js`

- [ ] **Step 1: Create `docs/glossary.js` with the data array**

```js
/* Echo web glossary — single source of truth.
   Data + glossary-page renderer + inline popover engine. No dependencies.
   category ∈ "Technical" | "Learning science" | "Formats & domain" */
(function () {
  "use strict";

  var GLOSSARY = [
    // ---- Technical -----------------------------------------------------
    { slug: "whisperkit", term: "WhisperKit", category: "Technical",
      short: "Apple-silicon speech-to-text that runs entirely on your device — no audio is ever uploaded.",
      long: "An on-device speech-recognition engine (OpenAI's Whisper model converted to Apple's CoreML). Echo uses it to 'listen' to a few seconds of narration and match it to the book text, so alignment needs no internet and no cloud service ever hears your audio." },
    { slug: "coreml", term: "CoreML", category: "Technical",
      short: "Apple's framework for running machine-learning models locally on iPhone and Mac hardware.",
      long: "Apple's on-device machine-learning runtime. It lets models like WhisperKit run fast on the phone's Neural Engine instead of on a server — the reason Echo's alignment is private and works offline." },
    { slug: "dtw", term: "TokenDTW / Dynamic Time Warping", category: "Technical",
      short: "An algorithm that lines up two sequences running at different speeds — here, spoken words vs. written words.",
      long: "Dynamic Time Warping finds the best correspondence between two sequences that drift in timing. Echo's TokenDTW matches the words it heard against the words on the page to pin each paragraph to the right moment in the audio, even when the narrator pauses, repeats, or skips." },
    { slug: "vad", term: "VAD (voice-activity detection)", category: "Technical",
      short: "Detecting where speech starts and stops, so audio can be cut at natural silences.",
      long: "Voice-activity detection finds the gaps between speech. Echo uses it to chop narration into clean chunks at silences before transcribing, which makes alignment faster and more accurate." },
    { slug: "levenshtein", term: "Levenshtein distance", category: "Technical",
      short: "A count of the single-character edits needed to turn one word into another — i.e. how similar they are.",
      long: "The number of insertions, deletions, or substitutions needed to change one string into another. Echo uses it to forgive small transcription errors when matching heard words to the book's text." },
    { slug: "jaccard", term: "Jaccard similarity", category: "Technical",
      short: "A 0–1 score for how much two sets of words overlap.",
      long: "A measure of overlap between two sets — shared items divided by total items. Echo compares the words in a heard passage against a paragraph's words to judge whether they're the same passage." },
    { slug: "grdb", term: "GRDB", category: "Technical",
      short: "The Swift library Echo uses to store your data in a local SQLite database on the device.",
      long: "A well-regarded Swift wrapper around SQLite. It's where Echo keeps bookmarks, flashcards, notes, and alignment data — all on your device, no server involved." },
    { slug: "schema-migration", term: "Schema migration", category: "Technical",
      short: "A versioned, automatic upgrade of the local database's structure when the app gains new features.",
      long: "When a new Echo version needs a new column or table, a numbered migration (e.g. Schema_V11) updates your existing database in place on first launch, so an app update never loses your data." },
    { slug: "security-scoped-bookmark", term: "Security-scoped bookmark", category: "Technical",
      short: "A token that lets Echo re-open a file you picked, across restarts, without copying it.",
      long: "An Apple security feature: when you grant Echo access to a file or folder, the app saves a 'security-scoped bookmark' so it can reopen exactly that location later without asking again — while the rest of your disk stays off-limits." },
    { slug: "keychain", term: "Keychain", category: "Technical",
      short: "Apple's encrypted store for small secrets — used here for those file-access tokens.",
      long: "The system's encrypted vault for sensitive data. Echo keeps security-scoped bookmark tokens there rather than in plain settings, so they're protected at rest." },
    { slug: "observable", term: "@Observable", category: "Technical",
      short: "A Swift feature that makes the screen update automatically when the underlying data changes.",
      long: "A modern Swift annotation that makes a data object 'observable': when its values change, any SwiftUI view showing them refreshes automatically. It's the backbone of how Echo's player UI stays in sync with playback." },
    { slug: "dependency-injection", term: "Dependency / closure injection", category: "Technical",
      short: "Building an object by handing it the helpers it needs, instead of letting it create its own.",
      long: "A design practice where a component is given ('injected') its collaborators from outside instead of constructing them internally. Echo's PlayerModel is assembled this way from 20-plus small services, which keeps each piece focused and testable." },
    { slug: "watchconnectivity", term: "WatchConnectivity (WCSession)", category: "Technical",
      short: "Apple's channel for the iPhone and Apple Watch apps to talk to each other.",
      long: "The framework that carries messages between Echo on iPhone and Echo on Apple Watch — play/pause, skip, scrub, bookmarks, and layout changes all flow over a WCSession in both directions." },
    { slug: "app-group", term: "App Group", category: "Technical",
      short: "A shared sandbox that lets the app and its widget read the same data.",
      long: "An Apple mechanism that lets related targets (the main app and its Home/Lock-Screen widget) share a small pocket of storage, so the widget can show the current track and progress." },
    { slug: "accelerate", term: "Accelerate", category: "Technical",
      short: "Apple's library of hand-optimized math, used for fast audio number-crunching.",
      long: "A high-performance Apple framework for vector and signal math. Echo leans on it for the heavy number work in silence detection and audio analysis so the UI never stalls." },

    // ---- Learning science ----------------------------------------------
    { slug: "spaced-repetition", term: "Spaced repetition (SRS)", category: "Learning science",
      short: "Reviewing material at growing intervals so it sticks with the least effort.",
      long: "A study method (and the systems that automate it, 'SRS') that schedules each review just before you'd forget. Echo's flashcards use it so you spend time only on what's about to slip, not what you already know." },
    { slug: "sm2", term: "SM-2 algorithm", category: "Learning science",
      short: "The classic formula that decides when each flashcard is shown next — the one Anki was built on.",
      long: "The scheduling algorithm behind spaced repetition: after each review it adjusts how long until the card returns, based on how easily you recalled it. Echo uses the same SM-2 that Anki popularised." },
    { slug: "context-dependent-memory", term: "Context-dependent memory", category: "Learning science",
      short: "We recall things better in the setting where we learned them; cues from that setting pull the memory back.",
      long: "Your brain encodes the surrounding environment alongside what you're learning, so re-encountering that environment (or even a photo of it) helps retrieve the memory. Echo's photo and place bookmarks turn this into a deliberate study tool." },
    { slug: "testing-effect", term: "The testing effect", category: "Learning science",
      short: "Recalling something from memory strengthens it far more than re-reading it.",
      long: "Also called retrieval practice: the act of pulling an answer out of your head, effortfully, builds memory better than passive review. It's why Echo's flashcards ask you to answer before revealing." },
    { slug: "cognitive-offloading", term: "Cognitive offloading", category: "Learning science",
      short: "Parking a thought somewhere trusted so your mind is free to keep going.",
      long: "Moving information out of your head into an external store (a note, a bookmark) so working memory isn't clogged. Echo's brain-dump and mark-now-card-later flows are built around it." },
    { slug: "dual-coding", term: "Dual coding", category: "Learning science",
      short: "Pairing words with images creates two memory paths to the same idea.",
      long: "The theory that information encoded both verbally and visually is recalled better, because there are two routes back to it. Echo's hybrid text-plus-audio reading and photo bookmarks lean on this." },
    { slug: "retrieval-cue", term: "Retrieval cue", category: "Learning science",
      short: "A trigger — a place, image, or question — that pulls a stored memory back to mind.",
      long: "Anything that helps you access a memory: a photo, a location, the narrator's voice. Echo deliberately attaches cues to what you learn so recall has something to grab." },
    { slug: "interleaving", term: "Interleaving", category: "Learning science",
      short: "Mixing different topics in one session instead of blocking them, which improves retention.",
      long: "Alternating between related topics or problem types rather than drilling one to exhaustion. It feels harder but builds more durable, flexible memory — a 'desirable difficulty.'" },

    // ---- Formats & domain ----------------------------------------------
    { slug: "epub", term: "EPUB", category: "Formats & domain",
      short: "The open ebook format — reflowable text, headings, and images — used as Echo's companion reader.",
      long: "A standard, open ebook file (essentially zipped web pages). Drop one beside your audiobook and Echo's Reader tab shows the text in sync with the narration." },
    { slug: "m4b", term: "M4B", category: "Formats & domain",
      short: "An audiobook file that bundles chapters and cover art into one tidy file.",
      long: "An audio container made for audiobooks: a single file with embedded chapter markers and artwork. Echo reads its chapters instantly and can match those chapter titles to the EPUB without any machine learning." },
    { slug: "opf-spine", term: "OPF spine", category: "Formats & domain",
      short: "The EPUB's list of sections in reading order.",
      long: "Inside an EPUB, the OPF file's 'spine' is the ordered list of content documents — the official reading order. Echo follows it to extract paragraphs in the right sequence." },
    { slug: "xhtml", term: "XHTML", category: "Formats & domain",
      short: "The strict, web-page-like markup that holds an EPUB's actual text.",
      long: "A stricter form of HTML. Each chapter of an EPUB is an XHTML document; Echo parses these to pull out paragraphs, headings, and images for the Reader." },
    { slug: "alignment", term: "Audio–text alignment", category: "Formats & domain",
      short: "The map that ties each paragraph of the book to the exact moment it's spoken.",
      long: "Alignment is what lets Echo scroll the text in time with the narration and jump from a sentence to its audio (and back). Echo can build it automatically on-device, and you can correct it anywhere." },
    { slug: "alignment-anchor", term: "Alignment anchor", category: "Formats & domain",
      short: "A single locked point pairing one paragraph with one timestamp; the map is drawn between anchors.",
      long: "A pinned correspondence between a spot in the text and a moment in the audio. Echo interpolates between anchors to time everything in between, and adds more anchors where it needs precision." },
    { slug: "drift", term: "Alignment drift / repair", category: "Formats & domain",
      short: "When text and audio gradually slip out of sync — and Echo's fix for it.",
      long: "Over a long chapter, small timing errors accumulate so the highlighted text runs ahead of or behind the voice. Echo detects this 'drift' and repairs it by inserting fresh anchors at word-level precision." },
    { slug: "continuous-alignment", term: "Continuous alignment", category: "Formats & domain",
      short: "An optional mode that keeps refining the audio-text map in the background while you listen.",
      long: "When enabled, Echo samples short windows of audio during playback, transcribes them on-device, and drops in correction anchors on the fly — alignment that improves the more you listen." },
    { slug: "chapter-atom", term: "Chapter atom (sub-section)", category: "Formats & domain",
      short: "A piece of a chapter that some audiobooks split out (e.g. 'Chapter 11.A'); Echo recombines them.",
      long: "Some audiobooks (Libation-style rips) break a chapter into lettered parts. Echo's grouping service collapses these 'atoms' back into one logical chapter while keeping the parts as scrubber tick marks for fine navigation." },
    { slug: "pitch-corrected", term: "Pitch-corrected speed", category: "Formats & domain",
      short: "Speeding up audio without the chipmunk effect — faster tempo, same natural voice.",
      long: "Playing audio above 1× normally raises the pitch; pitch correction speeds the tempo while keeping the voice at its natural pitch, so 1.5× still sounds human." }
  ];

  // Expose for later steps (engine + renderer are added in Tasks 2–4).
  window.__ECHO_GLOSSARY__ = GLOSSARY;
})();
```

- [ ] **Step 2: Verify the file parses**

Run: `node --check docs/glossary.js`
Expected: no output, exit code 0 (a syntax error would print and exit non-zero).

- [ ] **Step 3: Verify every slug is unique**

Run: `node -e "var a=require('fs').readFileSync('docs/glossary.js','utf8').match(/slug: \"[a-z0-9-]+\"/g).map(s=>s.slice(7,-1)); var d=a.filter((x,i)=>a.indexOf(x)!==i); console.log(d.length?('DUP: '+d):'OK '+a.length+' slugs')"`
Expected: `OK 33 slugs`

- [ ] **Step 4: Commit**

```bash
git add docs/glossary.js
git commit -m "feat(site): add glossary data (single source of truth)"
```

---

## Task 2: Category helpers + slug map

Add the small lookup helpers the renderer and engine both need.

**Files:**
- Modify: `docs/glossary.js`

- [ ] **Step 1: Replace the closing of the IIFE**

Find the end of the file:

```js
  // Expose for later steps (engine + renderer are added in Tasks 2–4).
  window.__ECHO_GLOSSARY__ = GLOSSARY;
})();
```

Replace it with:

```js
  var CATEGORIES = ["Technical", "Learning science", "Formats & domain"];

  function catId(cat) {
    return "cat-" + cat.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/(^-|-$)/g, "");
  }

  var bySlug = {};
  GLOSSARY.forEach(function (e) { bySlug[e.slug] = e; });

  // (renderer added in Task 3, engine in Task 4)

  window.__ECHO_GLOSSARY__ = { entries: GLOSSARY, bySlug: bySlug, catId: catId, categories: CATEGORIES };
})();
```

- [ ] **Step 2: Verify it parses**

Run: `node --check docs/glossary.js`
Expected: no output, exit 0.

- [ ] **Step 3: Verify catId output**

Run: `node -e "global.window={};require('./docs/glossary.js');var g=window.__ECHO_GLOSSARY__;console.log(g.categories.map(g.catId).join(','))"`
Expected: `cat-technical,cat-learning-science,cat-formats-domain`

- [ ] **Step 4: Commit**

```bash
git add docs/glossary.js
git commit -m "feat(site): add glossary category + slug helpers"
```

---

## Task 3: Glossary-page renderer

Add `renderGlossary(mount)` — builds grouped, anchored entries from the data.

**Files:**
- Modify: `docs/glossary.js`

- [ ] **Step 1: Insert the renderer where the `// (renderer added...)` comment is**

Replace this line:

```js
  // (renderer added in Task 3, engine in Task 4)
```

with:

```js
  function renderGlossary(mount) {
    if (!mount) return;
    mount.innerHTML = "";
    CATEGORIES.forEach(function (cat) {
      var entries = GLOSSARY.filter(function (e) { return e.category === cat; })
        .sort(function (a, b) { return a.term.localeCompare(b.term); });
      if (!entries.length) return;
      var section = document.createElement("section");
      section.className = "gloss-cat";
      var h2 = document.createElement("h2");
      h2.id = catId(cat);
      h2.textContent = cat;
      section.appendChild(h2);
      entries.forEach(function (e) {
        var h3 = document.createElement("h3");
        h3.id = e.slug;
        h3.className = "gloss-term-heading";
        h3.textContent = e.term;
        var p = document.createElement("p");
        p.textContent = e.long;
        section.appendChild(h3);
        section.appendChild(p);
      });
      mount.appendChild(section);
    });
  }

  document.addEventListener("DOMContentLoaded", function () {
    var root = document.getElementById("glossary-root");
    if (root) renderGlossary(root);
  });

  // (engine added in Task 4)
```

- [ ] **Step 2: Verify it parses**

Run: `node --check docs/glossary.js`
Expected: no output, exit 0.

- [ ] **Step 3: Commit**

```bash
git add docs/glossary.js
git commit -m "feat(site): render glossary page from data"
```

---

## Task 4: Inline popover engine

Upgrade every `a.gloss[data-term]` into an accessible hover/tap/keyboard popover. Unknown slugs are left as plain links and logged once.

**Files:**
- Modify: `docs/glossary.js`

- [ ] **Step 1: Replace the `// (engine added in Task 4)` line with the engine**

```js
  var pop = null, def = null, more = null;   // reusable popover + its parts
  var current = null;                         // the <a.gloss> currently shown
  var hideTimer = null;
  var hoverCapable = window.matchMedia ? window.matchMedia("(hover: hover)").matches : true;
  var touchPrimary = window.matchMedia ? window.matchMedia("(hover: none)").matches : false;

  function buildPopover() {
    pop = document.createElement("div");
    pop.className = "gloss-popover";
    pop.hidden = true;
    def = document.createElement("span");
    def.className = "gloss-popover-def";
    def.id = "gloss-pop-def";
    more = document.createElement("a");
    more.className = "gloss-popover-more";
    more.textContent = "Read full entry →";
    pop.appendChild(def);
    pop.appendChild(more);
    pop.addEventListener("mouseenter", cancelHide);
    pop.addEventListener("mouseleave", scheduleHide);
    document.body.appendChild(pop);
  }

  function cancelHide() { if (hideTimer) { clearTimeout(hideTimer); hideTimer = null; } }
  function scheduleHide() { cancelHide(); hideTimer = setTimeout(hide, 180); }

  function position(term) {
    var r = term.getBoundingClientRect();
    var sx = window.pageXOffset, sy = window.pageYOffset;
    pop.hidden = false;                         // measure with layout
    var pw = pop.offsetWidth, ph = pop.offsetHeight, gap = 8;
    var left = sx + r.left;
    left = Math.max(sx + gap, Math.min(left, sx + window.innerWidth - pw - gap));
    var top = sy + r.bottom + gap;
    if (r.bottom + gap + ph > window.innerHeight) top = sy + r.top - ph - gap; // flip up
    pop.style.left = left + "px";
    pop.style.top = Math.max(sy + gap, top) + "px";
  }

  function show(term, entry) {
    cancelHide();
    if (!pop) buildPopover();
    def.textContent = entry.short;
    more.href = term.href;                       // same target as the term itself
    if (current && current !== term) current.removeAttribute("aria-describedby");
    current = term;
    term.setAttribute("aria-describedby", "gloss-pop-def");
    position(term);
  }

  function hide() {
    cancelHide();
    if (pop) pop.hidden = true;
    if (current) { current.removeAttribute("aria-describedby"); current = null; }
  }

  function enhance(term) {
    var slug = term.getAttribute("data-term");
    var entry = bySlug[slug];
    if (!entry) {
      console.warn('[glossary] no entry for data-term="' + slug + '" — left as a plain link:', term);
      return;
    }
    term.addEventListener("mouseenter", function () { if (hoverCapable) show(term, entry); });
    term.addEventListener("mouseleave", function () { if (hoverCapable) scheduleHide(); });
    term.addEventListener("focus", function () { show(term, entry); });
    term.addEventListener("blur", scheduleHide);
    term.addEventListener("click", function (ev) {
      if (touchPrimary) {                         // tap: peek instead of navigating away
        ev.preventDefault();
        if (current === term && pop && !pop.hidden) { hide(); } else { show(term, entry); }
      }
    });
  }

  document.addEventListener("DOMContentLoaded", function () {
    var terms = document.querySelectorAll("a.gloss[data-term]");
    for (var i = 0; i < terms.length; i++) enhance(terms[i]);
  });

  document.addEventListener("keydown", function (e) { if (e.key === "Escape") hide(); });
  document.addEventListener("click", function (e) {
    if (!pop || pop.hidden) return;
    if (e.target.closest && (e.target.closest(".gloss-popover") || e.target.closest("a.gloss"))) return;
    hide();
  });
```

- [ ] **Step 2: Verify it parses**

Run: `node --check docs/glossary.js`
Expected: no output, exit 0.

- [ ] **Step 3: Commit**

```bash
git add docs/glossary.js
git commit -m "feat(site): add accessible inline glossary popover engine"
```

---

## Task 5: Glossary styles

Append the term + popover + glossary-page styles to the shared stylesheet, using existing tokens.

**Files:**
- Modify: `docs/styles.css` (append at end of file)

- [ ] **Step 1: Append this block to the end of `docs/styles.css`**

```css
/* ===================================================================== */
/* Glossary                                                              */
/* ===================================================================== */
.gloss {
  color: inherit;
  text-decoration: none;
  border-bottom: 1px dotted var(--accent-gold);
  cursor: help;
}
.gloss:hover,
.gloss:focus-visible { color: var(--accent-gold); }

.gloss-popover {
  position: absolute;
  z-index: 100;
  max-width: 320px;
  background: var(--bg-raised);
  color: var(--text-primary);
  border: 1px solid var(--accent-gold);
  border-radius: 12px;
  padding: 0.85rem 1rem;
  box-shadow: 0 10px 30px rgba(0, 0, 0, 0.45);
  font-size: 0.9rem;
  line-height: 1.5;
}
.gloss-popover[hidden] { display: none; }
.gloss-popover-def { display: block; }
.gloss-popover-more {
  display: inline-block;
  margin-top: 0.55rem;
  color: var(--link);
  font-size: 0.82rem;
  text-decoration: none;
}
.gloss-popover-more:hover { text-decoration: underline; }

.gloss-cat { margin-bottom: 2.4rem; }
.gloss-term-heading {
  font-size: 1.15rem;
  color: var(--accent-gold);
  margin: 1.4rem 0 0.3rem;
  scroll-margin-top: 6rem; /* clear the sticky header when jumping to an anchor */
}

@media (prefers-reduced-motion: no-preference) {
  .gloss-popover { animation: gloss-fade 0.12s ease-out; }
  @keyframes gloss-fade {
    from { opacity: 0; transform: translateY(4px); }
    to   { opacity: 1; transform: none; }
  }
}
```

- [ ] **Step 2: Commit**

```bash
git add docs/styles.css
git commit -m "style(site): add glossary term, popover, and page styles"
```

---

## Task 6: The glossary page

Create `docs/glossary.html` with standard site chrome, a static 3-link category TOC, and the render mount. The footer here already uses the **reworded** fineprint (Task 7 brings the other pages in line).

**Files:**
- Create: `docs/glossary.html`

- [ ] **Step 1: Create `docs/glossary.html`**

```html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Glossary — Echo</title>
    <meta name="description" content="Plain-language definitions for every bit of jargon in Echo and its docs: WhisperKit, spaced repetition, alignment, EPUB, and more.">
    <meta property="og:title" content="Echo Glossary">
    <meta property="og:description" content="Plain-language definitions for the technical, learning-science, and audiobook terms used throughout Echo.">
    <meta property="og:image" content="https://dfakkeldy.github.io/Echo/assets/icon.png">
    <meta property="og:url" content="https://dfakkeldy.github.io/Echo/glossary.html">
    <meta property="og:type" content="article">
    <link rel="stylesheet" href="styles.css">
    <link rel="icon" type="image/png" href="assets/icon.png">
</head>
<body>
    <a class="skip-link" href="#main">Skip to content</a>

    <header class="site-header">
        <div class="logo-container">
            <a href="index.html">
                <img src="assets/icon.png" alt="Echo app icon — an infinity symbol in silver and gold">
                <span class="logo-text">Echo <span class="infinity">∞</span></span>
            </a>
        </div>
        <nav class="site-nav" aria-label="Main">
            <a href="index.html">Home</a>
            <a href="learn.html">Learn</a>
            <a href="focus.html">Focus</a>
            <a href="manual.html">Manual</a>
            <a href="devlog.html">Devlog</a>
            <a href="glossary.html" aria-current="page">Glossary</a>
            <a class="nav-cta" href="https://github.com/dfakkeldy/Echo" target="_blank" rel="noopener noreferrer">GitHub</a>
        </nav>
    </header>

    <main id="main">
        <div class="page-hero">
            <p class="section-label">Reference</p>
            <h1>Glossary</h1>
            <p>
                Plain-language definitions for the jargon used across Echo, its docs, and this site —
                grouped into the technical machinery, the learning science, and the audiobook formats.
                Anywhere you see a <span class="gloss">dotted underline</span> on the site, hover or tap it
                for a quick definition; this page holds the full versions.
            </p>
        </div>

        <div class="docs-layout">
            <aside class="docs-toc" aria-label="Categories">
                <h2>Categories</h2>
                <ol>
                    <li><a href="#cat-technical">Technical</a></li>
                    <li><a href="#cat-learning-science">Learning science</a></li>
                    <li><a href="#cat-formats-domain">Formats &amp; domain</a></li>
                </ol>
            </aside>

            <article class="prose">
                <div id="glossary-root">
                    <p><em>Definitions load with a small first-party script. If they didn't appear,
                    enable JavaScript — or read the raw definitions in
                    <a href="https://github.com/dfakkeldy/Echo/blob/main/docs/glossary.js">glossary.js</a>.</em></p>
                </div>
            </article>
        </div>
    </main>

    <footer class="site-footer">
        <div class="footer-links">
            <a href="beta.html">Beta</a>
            <a href="learn.html">Learn</a>
            <a href="focus.html">Focus</a>
            <a href="manual.html">Manual</a>
            <a href="devlog.html">Devlog</a>
            <a href="glossary.html">Glossary</a>
            <a href="privacy.html">Privacy</a>
            <a href="https://github.com/dfakkeldy/Echo" target="_blank" rel="noopener noreferrer">GitHub</a>
            <a href="https://github.com/dfakkeldy/Echo/issues" target="_blank" rel="noopener noreferrer">Support</a>
        </div>
        <p>&copy; 2026 Echo. Open source under the GPL-3.0 License.</p>
        <p class="footer-fineprint">This site is set in OpenDyslexic, hosts its own fonts, runs one small first-party script (the glossary), sets no cookies, and makes no network calls.</p>
    </footer>

    <script defer src="glossary.js"></script>
</body>
</html>
```

- [ ] **Step 2: Verify in the browser**

Start the static server (if not already running): `python3 -m http.server 8123 --directory docs` (background).
Open `http://localhost:8123/glossary.html` with the preview tools.
- `preview_console_logs` → **no errors and no `[glossary]` warnings**.
- `preview_snapshot` → three category headings ("Technical", "Learning science", "Formats & domain") each followed by term headings and paragraphs; ~33 terms total.
- `preview_click` the TOC "Formats & domain" link → page jumps to that section (heading clears the sticky header, not hidden underneath it).

- [ ] **Step 3: Commit**

```bash
git add docs/glossary.html
git commit -m "feat(site): add the glossary page"
```

---

## Task 7: Wire the glossary into every page (nav, footer, script, fineprint)

Add the Glossary nav link, footer link, the `<script defer>`, and the **reworded fineprint** to every other page. Uniform footers keep the "first-party script" claim true and identical site-wide.

**Files (8):** `docs/index.html`, `docs/learn.html`, `docs/focus.html`, `docs/manual.html`, `docs/devlog.html`, `docs/beta.html`, `docs/privacy.html`, `docs/terms.html`

For **each** of the 8 files, make these four edits. The anchor strings are identical across pages, so the same find/replace works everywhere.

- [ ] **Step 1: Add the Glossary nav link** (before the GitHub nav CTA)

Find:
```html
            <a class="nav-cta" href="https://github.com/dfakkeldy/Echo" target="_blank" rel="noopener noreferrer">GitHub</a>
```
Replace with:
```html
            <a href="glossary.html">Glossary</a>
            <a class="nav-cta" href="https://github.com/dfakkeldy/Echo" target="_blank" rel="noopener noreferrer">GitHub</a>
```
(Note: `privacy.html` and `terms.html` have a shorter nav but the same `nav-cta` line — this still applies.)

- [ ] **Step 2: Add the Glossary footer link** (before the Privacy footer link)

Find:
```html
            <a href="privacy.html">Privacy</a>
```
Replace with:
```html
            <a href="glossary.html">Glossary</a>
            <a href="privacy.html">Privacy</a>
```
(If a page's footer has no Privacy link, instead add `<a href="glossary.html">Glossary</a>` immediately before the GitHub footer link.)

- [ ] **Step 3: Reword the fineprint**

Find:
```html
        <p class="footer-fineprint">This site is set in OpenDyslexic, hosts its own fonts, runs no scripts, and sets no cookies.</p>
```
Replace with:
```html
        <p class="footer-fineprint">This site is set in OpenDyslexic, hosts its own fonts, runs one small first-party script (the glossary), sets no cookies, and makes no network calls.</p>
```

- [ ] **Step 4: Add the script tag** (immediately before `</body>`)

Find:
```html
</body>
</html>
```
Replace with:
```html

    <script defer src="glossary.js"></script>
</body>
</html>
```

- [ ] **Step 5: Verify no page still claims "runs no scripts"**

Run: `grep -rn "runs no scripts" docs/*.html || echo "OK none left"`
Expected: `OK none left`

- [ ] **Step 6: Verify all 8 pages load the script and have the nav link**

Run: `grep -lc 'src="glossary.js"' docs/index.html docs/learn.html docs/focus.html docs/manual.html docs/devlog.html docs/beta.html docs/privacy.html docs/terms.html docs/glossary.html | wc -l`
Expected: `9` (8 pages + the glossary page from Task 6).

Run: `grep -c '>Glossary<' docs/*.html | grep -c ':0' || echo "all have Glossary link"`
Expected: `all have Glossary link` (no file shows `:0`).

- [ ] **Step 7: Commit**

```bash
git add docs/*.html
git commit -m "feat(site): add glossary nav/footer links and reword the no-scripts footer

The site now ships one first-party script (the glossary), so the footer
fineprint is updated on every page to stay accurate."
```

---

## Task 8: Inline markup on `learn.html`

Mark up the first meaningful mention of six learning-science terms. Each edit wraps existing text in an `<a class="gloss">` — no wording changes.

**Files:**
- Modify: `docs/learn.html`

- [ ] **Step 1: cognitive offloading** (line ~80)

Find:
```html
information into long-term memory: retrieval practice, spacing, context cues, cognitive offloading,
```
Replace with:
```html
information into long-term memory: retrieval practice, spacing, context cues, <a class="gloss" href="glossary.html#cognitive-offloading" data-term="cognitive-offloading">cognitive offloading</a>,
```

- [ ] **Step 2: context-dependent memory** (line ~93)

Find:
```html
                    <span class="label">The Science · Context-Dependent Memory</span>
```
Replace with:
```html
                    <span class="label">The Science · <a class="gloss" href="glossary.html#context-dependent-memory" data-term="context-dependent-memory">Context-Dependent Memory</a></span>
```

- [ ] **Step 3: retrieval cue** (line ~94)

Find:
```html
the environment acts as a retrieval cue that pulls the information back up.
```
Replace with:
```html
the environment acts as a <a class="gloss" href="glossary.html#retrieval-cue" data-term="retrieval-cue">retrieval cue</a> that pulls the information back up.
```

- [ ] **Step 4: spaced repetition** (heading, line ~120)

Find:
```html
                <h2 id="srs"><span class="sec-num">02</span>The Study System — spaced repetition, explained from zero</h2>
```
Replace with:
```html
                <h2 id="srs"><span class="sec-num">02</span>The Study System — <a class="gloss" href="glossary.html#spaced-repetition" data-term="spaced-repetition">spaced repetition</a>, explained from zero</h2>
```

- [ ] **Step 5: SM-2** (line ~125)

Find:
```html
it uses the same SM-2 scheduling algorithm Anki was built on,
```
Replace with:
```html
it uses the same <a class="gloss" href="glossary.html#sm2" data-term="sm2">SM-2</a> scheduling algorithm Anki was built on,
```

- [ ] **Step 6: the testing effect** (heading, line ~148)

Find:
```html
                <h2 id="grading"><span class="sec-num">03</span>Honest Grading — the testing effect</h2>
```
Replace with:
```html
                <h2 id="grading"><span class="sec-num">03</span>Honest Grading — <a class="gloss" href="glossary.html#testing-effect" data-term="testing-effect">the testing effect</a></h2>
```

- [ ] **Step 7: Verify in the browser**

Open `http://localhost:8123/learn.html`.
- `preview_console_logs` → no `[glossary]` warnings (every `data-term` resolved).
- Hover the "spaced repetition" link → popover appears with its short definition + "Read full entry →".
- `preview_click` the "Read full entry →" link → lands on `glossary.html#spaced-repetition`.
- Tab through with the keyboard → focusing a term shows the popover; Escape closes it.

- [ ] **Step 8: Commit**

```bash
git add docs/learn.html
git commit -m "docs(site): add glossary popovers to learn.html"
```

---

## Task 9: Inline markup on `manual.html`

Mark up the first meaningful mention of four format/domain + study terms.

**Files:**
- Modify: `docs/manual.html`

- [ ] **Step 1: M4B** (line ~93)

Find:
```html
                    <li><strong>M4B</strong> — with full embedded chapter parsing, including books split across multiple M4B files (chapters are aggregated automatically)</li>
```
Replace with:
```html
                    <li><strong><a class="gloss" href="glossary.html#m4b" data-term="m4b">M4B</a></strong> — with full embedded chapter parsing, including books split across multiple M4B files (chapters are aggregated automatically)</li>
```

- [ ] **Step 2: EPUB** (line ~95)

Find:
```html
                    <li><strong>EPUB</strong> — as a synced companion text (see <a href="#reader">The Reader</a>)</li>
```
Replace with:
```html
                    <li><strong><a class="gloss" href="glossary.html#epub" data-term="epub">EPUB</a></strong> — as a synced companion text (see <a href="#reader">The Reader</a>)</li>
```

- [ ] **Step 3: spaced repetition** (line ~287)

Find:
```html
                <p>Echo includes a complete spaced-repetition system (SRS) — think Anki, built into your audiobook player, with audio on the cards.
```
Replace with:
```html
                <p>Echo includes a complete <a class="gloss" href="glossary.html#spaced-repetition" data-term="spaced-repetition">spaced-repetition system (SRS)</a> — think Anki, built into your audiobook player, with audio on the cards.
```

- [ ] **Step 4: alignment** (line ~403)

Find:
```html
                <p>Alignment is what binds the reader to the narration: every paragraph gets a timestamp.
```
Replace with:
```html
                <p><a class="gloss" href="glossary.html#alignment" data-term="alignment">Alignment</a> is what binds the reader to the narration: every paragraph gets a timestamp.
```

- [ ] **Step 5: Verify in the browser**

Open `http://localhost:8123/manual.html`.
- `preview_console_logs` → no `[glossary]` warnings.
- Hover "M4B" and "EPUB" → correct popovers.
- `preview_resize` to a phone width (e.g. 390×844), then `preview_click` the "EPUB" term → popover opens on tap; click elsewhere → it closes.

- [ ] **Step 6: Commit**

```bash
git add docs/manual.html
git commit -m "docs(site): add glossary popovers to manual.html"
```

---

## Task 10: README integration

The README can't pop (GitHub strips the script), so it links out. Add a discoverability row, a pointer line, and a few first-mention out-links.

**Files:**
- Modify: `README.md`

- [ ] **Step 1: Add a Glossary row to the Documentation table** (after the Website row)

Find:
```markdown
| 🌐 [Website](https://dfakkeldy.github.io/Echo/) | Marketing home: the story, the features, the science |
```
Replace with:
```markdown
| 🌐 [Website](https://dfakkeldy.github.io/Echo/) | Marketing home: the story, the features, the science |
| 📚 [Glossary](https://dfakkeldy.github.io/Echo/glossary.html) | Plain-language definitions for every term below — hover any dotted-underlined word on the site |
```

- [ ] **Step 2: Add a pointer line under the Overview heading**

Find:
```markdown
## Overview

Echo is a full-featured audiobook study application
```
Replace with:
```markdown
## Overview

> 💡 New to a term in this section or the next? Look it up in the [Glossary](https://dfakkeldy.github.io/Echo/glossary.html) — on the website, technical words carry hover-to-define popovers.

Echo is a full-featured audiobook study application
```

- [ ] **Step 3: Link first-mention terms in the True ePub feature bullet**

Find:
```markdown
On-device auto-alignment (WhisperKit + CoreML) maps every paragraph to the narration
```
Replace with:
```markdown
On-device auto-alignment ([WhisperKit](https://dfakkeldy.github.io/Echo/glossary.html#whisperkit) + [CoreML](https://dfakkeldy.github.io/Echo/glossary.html#coreml)) maps every paragraph to the narration
```

- [ ] **Step 4: Link the matcher + DTW terms in the Overview paragraph**

Find:
```markdown
fuzzy-matching them against the EPUB text (Levenshtein + Jaccard) to create precise alignment anchors. Drift detection finds misaligned chapters, and drift repair uses TokenDTW (Dynamic Time Warping) to insert correction anchors
```
Replace with:
```markdown
fuzzy-matching them against the EPUB text ([Levenshtein](https://dfakkeldy.github.io/Echo/glossary.html#levenshtein) + [Jaccard](https://dfakkeldy.github.io/Echo/glossary.html#jaccard)) to create precise alignment anchors. Drift detection finds misaligned chapters, and drift repair uses [TokenDTW (Dynamic Time Warping)](https://dfakkeldy.github.io/Echo/glossary.html#dtw) to insert correction anchors
```

- [ ] **Step 5: Verify the links resolve to real anchors**

Run: `for s in whisperkit coreml levenshtein jaccard dtw; do grep -q "slug: \"$s\"" docs/glossary.js && echo "$s OK" || echo "$s MISSING"; done`
Expected: all five print `OK`.

- [ ] **Step 6: Commit**

```bash
git add README.md
git commit -m "docs: link README jargon to the web glossary"
```

---

## Task 11: Full verification pass

End-to-end check across input modes, then a docs-sync check. No code changes unless a check fails.

**Files:** none (verification only)

- [ ] **Step 1: Desktop hover + keyboard**

Open `http://localhost:8123/learn.html`.
- Hover each of the 6 terms → each shows its own short definition (not a stale/previous one).
- Keyboard-Tab to a term → popover appears with a visible gold focus ring; Escape closes it; Tab away closes it.

- [ ] **Step 2: Touch / mobile**

`preview_resize` to 390×844, open `http://localhost:8123/manual.html`.
- Tap "EPUB" → popover opens (page does not navigate).
- Tap the "Read full entry →" inside → navigates to `glossary.html#epub`.
- Re-open, tap outside the popover → it closes.

- [ ] **Step 3: Reduced motion**

In the preview browser, emulate `prefers-reduced-motion: reduce` (e.g. `preview_eval` to set the emulation, or note it as a manual check). Confirm the popover appears with no fade/slide animation.

- [ ] **Step 4: No-JS fallback**

`preview_eval`: temporarily block the script by opening `http://localhost:8123/learn.html` with JS disabled (or rename the request). Confirm each term is still a working link that navigates to its `glossary.html#slug` entry, and the glossary page shows its enable-JavaScript fallback note.

- [ ] **Step 5: Console is clean site-wide**

Open each of `glossary.html`, `learn.html`, `manual.html` in turn and confirm `preview_console_logs` shows zero errors and zero `[glossary]` warnings.

- [ ] **Step 6: Stop the static server**

Terminate the `python3 -m http.server 8123` background process.

- [ ] **Step 7: Docs sync**

Confirm `README.md` now lists the Glossary (Task 10, Step 1). No `ARCHITECTURE.md` change is required — this is site content, not app architecture. If `CHANGELOG.md` tracks site changes, add a one-line entry under the current unreleased section:
```markdown
- Website: added a plain-language Glossary with hover/tap definitions across the site.
```

- [ ] **Step 8: Final commit (if Step 7 changed CHANGELOG)**

```bash
git add CHANGELOG.md
git commit -m "docs: note web glossary in changelog"
```

---

## Self-review (completed by plan author)

**Spec coverage:**
- Single source of truth (`glossary.js`) → Tasks 1–4. ✓
- Glossary page rendered from data → Tasks 3, 6. ✓
- Inline popover engine, hover + tap + keyboard, edge-aware, dismissible → Task 4. ✓
- Progressive enhancement / no-JS link fallback / unknown-slug warning → Task 4 (`enhance` guard + `console.warn`), Task 6 (fallback note), Task 11 Step 4. ✓
- Styling from existing tokens, reduced-motion → Task 5. ✓
- All three categories, ~30 terms → Task 1 (33 terms). ✓
- Markup on learn.html + manual.html, first mention only → Tasks 8, 9. ✓
- README out-links + pointer → Task 10. ✓
- "Runs no scripts" footer reworded honestly → Task 7. ✓
- Verification is browser-based (no test runner) → Tasks 6, 8, 9, 11. ✓
- YAGNI: no search box, no build step, no README popovers → respected. ✓

**Placeholder scan:** No TBD/TODO; every code/markup step shows full content; every command has expected output. ✓

**Type/name consistency:** `bySlug` (object), `catId()`, `CATEGORIES`, `renderGlossary()`, `enhance()`, `show()/hide()`, ids `glossary-root` / `gloss-pop-def`, classes `gloss` / `gloss-popover` / `gloss-popover-def` / `gloss-popover-more` / `gloss-term-heading` / `gloss-cat` — all used consistently across Tasks 1–9. The `data-term` slugs in Tasks 8–10 (`cognitive-offloading`, `context-dependent-memory`, `retrieval-cue`, `spaced-repetition`, `sm2`, `testing-effect`, `m4b`, `epub`, `alignment`, `whisperkit`, `coreml`, `levenshtein`, `jaccard`, `dtw`) all exist in the Task 1 data. ✓
