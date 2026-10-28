# Maintaining Echo's documentation

The public site is plain HTML/CSS with one first-party glossary script. It has no build-time frontend framework, analytics, or external font service. Preview it from the repository root:

```sh
python3 -m http.server 8768 --directory docs
```

Open `http://localhost:8768/`. Check both a desktop width and a narrow phone width; visit the manual, a guide, the glossary, beta, and legal pages. Test navigation and keyboard focus as well as appearance.

## Which source to update

| Material | Source |
|---|---|
| Project overview | `README.md` |
| Current user workflows | `guides/user-manual.md` and `manual.html` |
| Learning/focus guides | `guides/getting-the-most-out-of-echo.md` + `learn.html`; `guides/focus-field-guide.md` + `focus.html` |
| Beta guidance | `guides/testflight-beta-guide.md` and `beta.html` |
| Glossary data and popovers | `glossary.js` |
| Shared site layout | `styles.css` and the header/footer in each HTML page |
| Development history | `guides/devlog.md` and `devlog.html`; the automated block has explicit markers |
| Developer architecture/plans | `../ARCHITECTURE.md`, `../ROADMAP.md`, and dated reports/specs |
| Code audits and review snapshots | `audits/` (historical; source comments citing `CODE_AUDIT.md §n` mean `audits/CODE_AUDIT.md` or an earlier version of it in git history) |
| Agent handoff notes | `handoffs/` (working notes for unfinished tasks, kept for history) |
| Format contracts | `epub-pronunciation-authoring.md`, `pdf-readalong-authoring.md`, `phonon-narration.md` |

Update both Markdown and HTML when changing a guide. Preserve existing public section fragments; the manual includes aliases for numbered Markdown headings as well as older short HTML fragments. Pandoc can assist with body conversion, but review relative links, heading IDs, tables, and the surrounding page shell before saving. Do not replace an author's historical claims with a new review date.

The current guide pass was reviewed against Nightly source on October 24, 2026. An implemented service is not necessarily reachable UI. A source merge is not a TestFlight upload or App Store release. Describe optional network transfers by feature; local inference does not mean the entire app is offline. Use the manual's platform/sync boundaries when writing summaries.

## Checks

```sh
make doc-contract-test doc-automation-test
```

The documentation contracts run without Xcode and protect Settings paths, removed UI vocabulary, and public-alignment availability. Check local links/assets and every changed fragment, inspect rendered pages at narrow widths, and run `git diff --check` before a PR. Documentation-only CI can skip Apple builds; do not report that as app compilation or device verification.

`make architecture` regenerates the source tree while preserving content below `<!-- MANUAL BELOW -->`. `make devlog-update` refreshes the previous calendar week's digest; explicit date ranges are available through `python3 -m doc_automation.devlog` with `PYTHONPATH=Scripts`. Its generated “Shipped” category means source changes, not distribution receipts. Keep historical entries dated.

## Publication

The GitHub Pages site currently builds from **`main` → `/docs`** (verified October 24, 2026). Ordinary feature/documentation PRs target **`nightly`**. Merging a Nightly docs change does not update the live site.

Website publication needs a separately authorized docs-only update to the publishing branch or the normal release promotion. Do not promote unrelated app code or change Pages settings just to publish docs. Verify the hosted page after publication; PR merge, Pages build, and live content are separate checks.

This GitHub Pages site is the public documentation. [KinNoKi Labs](https://kinnokilabs.com/apps/echo) remains the separate marketing home; updates here do not modify that site.
