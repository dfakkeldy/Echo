---
name: echo-manual-epub
description: >-
  Build or refresh "Welcome to Echo — The Listener's Manual", the in-app narrated
  user manual that ships inside Echo (a chaptered EPUB Echo narrates on-device,
  with placeholder screenshots users can view while listening). Use whenever the
  user wants to (re)generate, rebuild, refresh, update, or version-bump the Echo
  manual / in-app manual / user-manual EPUB / "the listener's manual" / the bundled
  manual audiobook — including when the manual has gone stale after features
  shipped, when cutting a v1.1 / v2 edition, or when they say "the manual needs
  redoing." Pulls content from Echo's own docs (user-manual.md,
  getting-the-most-out-of-echo.md, ROADMAP.md), writes narration-ready chapters,
  generates placeholder screenshots, and assembles the EPUB + Markdown. This is the
  Echo-specific specialization of the general explainer-audiobook skill.
---

# Echo Manual EPUB

This builds **"Welcome to Echo — The Listener's Manual"** — the user manual that
ships *inside* Echo as an EPUB and is narrated on-device by Echo itself. A new user
can start listening the moment they download the app, and view the screenshots they
miss by opening the Read tab. It is rebuilt often as the app evolves, so the whole
pipeline is scripted and reproducible.

It is the Echo-specific specialization of the general **explainer-audiobook** skill:
same narration craft (write 100% for the ear, never read code aloud, name the real
things), plus Echo's content map, chapter outline, status discipline, image
workflow, and bundled build scripts. If the explainer-audiobook skill is installed,
its `references/narration-style.md` is the fuller treatment of the voice; this skill
is self-sufficient without it.

**Read `references/chapter-plan.md` first** — it carries the content sources, the
16-chapter outline, the status-flag discipline, the throughlines, the verbatim
voice & rules block, and the writer-prompt template. Everything below is the
mechanical workflow around it.

## Authorship (fixed)

- **Author (`dc:creator`) = Dan Fakkeldy** everywhere (the human owner; the
  book-ingestion workflow keys on a stable human author).
- **Contributor (metadata only) = the generating model** — pass your own
  human-friendly model name (e.g. "Opus 4.8", "Sonnet 4.6") to `--contributor`.
- Title: **Welcome to Echo**. Subtitle: **The Listener's Manual**.

## Workflow

Track these with a TodoList. Default build directory:
`~/Developer/echo-manual-build/welcome-to-echo` (off git). Subfolders: `chapters/`,
`images/`, `dist/`.

### 1. Refresh the facts (don't trust the last build's prose)
Re-read the content sources listed in `references/chapter-plan.md` — the user
manual, the learning guide, and ROADMAP Part A — and note what changed since last
time: new features, features that graduated from 🚧 to shipped, new roadmap items.
The manual must describe the app **as it is now**.

### 2. Confirm the outline and the edition
Present the chapter outline (default: the 16 in `chapter-plan.md`) and the target
version it documents (e.g. v1.0, v1.1). Get a yes before generating — regenerating
tens of thousands of words against the wrong outline is the expensive mistake. Add,
cut, or reorder chapters to match what shipped.

### 3. Build per-chapter fact packs + beats
For each chapter, assemble a fact pack (real names + the one-breath "why" + the
correct **status phrase** for each unshipped feature) and a 6–7 beat sheet. This is
the accuracy backbone — writers must not invent beyond it. The mapping of chapters
to user-manual sections is in `chapter-plan.md`.

### 4. Fan out the writers (one agent per chapter)
Pre-create `chapters/`. Dispatch one Agent per chapter, in parallel batches of ~6,
each with: the voice & rules block + throughlines + full title list + its own beats
and fact pack. `model: sonnet` is a good fit. Each writes `chapters/chNN.md`
(zero-padded) and returns a word count. Use the writer-prompt template in
`chapter-plan.md`. **Writers place no images.**

### 5. Generate the placeholder screenshots
```bash
python3 scripts/generate_placeholders.py --build-dir <build>
```
Edit the `FIGURES` list in that script to add/retarget screenshots (it's the single
source of truth; it also writes `figures.json`). Each placeholder renders its
"what to shoot" note into the pixels; only the short caption reaches the EPUB text.
These are deliberately placeholders, not real screenshots, unless the owner says
otherwise.

### 6. Inject the figures
```bash
python3 scripts/inject_figures.py --build-dir <build>
```
Inserts `![caption](imgNN.png)` lines at spread paragraph boundaries. Idempotent.

### 7. QC sweep (cheap shell checks)
From `chapters/`:
- Word counts: `wc -w ch*.md` — top up any well under ~2,700.
- Headings: every file's first line is `## Chapter N — Title`.
- Code-leak: `grep -l '`' ch*.md`; snake_case `grep -hoE '[A-Za-z]+_[A-Za-z_]+'`;
  arrows/braces/empty-calls `grep -nE -- '->|[{}]|\b[a-zA-Z]+\(\)'` — all empty.
- Dead phrases: `grep -rniE 'tattoo|the single most important|the whole (point|show|game)|if you remember nothing else' ch*.md` — rewrite any hit.
- Status flags present: `grep -rciE 'version one-point-oh|on the roadmap' ch*.md`
  — every chapter with an unshipped feature should name it aloud.
- Spot-read the opener (ch00) and the most technical chapter for voice + accuracy;
  watch for overstated claims (e.g. precise location — Context Memory is opt-in and
  approximate).

### 8. Build the EPUB + Markdown
```bash
python3 scripts/build_book_images.py \
  --chapters-dir <build>/chapters --out-dir <build>/dist --images-dir <build>/images \
  --title "Welcome to Echo" --author "Dan Fakkeldy" --contributor "<model>" \
  --subtitle "The Listener's Manual" --slug Welcome-to-Echo \
  --cover <build>/dist/cover.png
```
This image-capable builder (a fork of the explainer-audiobook builder) packages the
PNGs into `OEBPS/images/`, renders `---` scene-breaks as silent `<hr/>` (so they're
never narrated), and writes a valid EPUB 3 with nav + NCX. Verify:
`python3 -c "import zipfile;z=zipfile.ZipFile('<build>/dist/Welcome-to-Echo.epub');i=z.infolist()[0];print(i.filename,i.compress_type)"`
must print `mimetype 0`.

### 9. Cover
Author 2–3 bespoke SVG concepts (dark backdrop, light line-work, one warm accent,
no baked-in text) and render with the explainer-audiobook `make_cover.py` (`--art`,
`--layout bleed|hero`); send candidates and let the owner pick. The chosen cover for
the current edition is the "book + echo rings" concept (bleed). Note the title-band
hue is seeded from the title (came out warm maroon); pass `--seed` to retune.

### 10. Deliver
Copy to the book inbox and send both files:
```bash
mkdir -p ~/Downloads/book-inbox
cp <build>/dist/Welcome-to-Echo.epub ~/Downloads/book-inbox/
```
Report the real word count and honest runtime (the builder prints both). If the app
ships the EPUB as a bundled resource, remind the owner to drop the new file into the
app's resources — that is a separate app change, not part of this skill.

## Gotchas learned in production
- **Narration is a v1.0 headline the website manual under-covers** — on-device
  narration (Kokoro) and Echo Pro (one-time unlock, free tier = 20 cards + 1
  narrated chapter) deserve full treatment. Check ROADMAP §A.1/§A.2 each rebuild.
- **The book is its own demo.** It's narrated by Echo and read in the Read tab, so
  it can quietly show off read-along, narration, and "view images later."
- **Don't mutate the shared explainer-audiobook `build_book.py`** — it has no image
  support. Use the bundled `build_book_images.py`.
- **`---` lines must become `<hr/>`, not text** — the builder handles this; if you
  ever swap builders, re-check, or Echo will narrate "dash dash dash."
- Writers reliably land ~2,700–3,100 words from a 6–7 beat sheet; trust `wc -w`,
  not their self-reported counts.
