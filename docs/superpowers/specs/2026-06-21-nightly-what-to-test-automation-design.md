# Doc & Marketing Surface Automation — Program + Phase 1 Design

**Date:** 2026-06-21
**Status:** Design approved; spec under review
**Scope of this document:** the overall automation *program* (context for all phases) plus the **implementable Phase 1 design**. Phases 2–4 are sketched only enough to justify the sequencing; each gets its own spec when reached.

---

## 1. Problem

Every shipped feature obliges manual updates across a slew of surfaces: in-repo living docs, TestFlight copy, App Store metadata, and three separate websites. The maintainer asked whether this should "be built into the nightly." It should not — *as a single nightly job* — because these surfaces fire at different points on Echo's promotion ladder (`feature → nightly → weekly → main`) and carry very different risk.

### Three-tier risk model (the load-bearing constraint)

| Tier | Surfaces | Rule |
|---|---|---|
| **Mechanical** — safe to auto-generate | ARCHITECTURE.md tree (already `make architecture`), structural validators, ROADMAP checkbox flips | Deterministic from code; no judgment |
| **Draft-then-human-ratify** | `testflight/what_to_test.txt`, App Store `release_notes.txt`/`description.txt`, README feature list | Reaches testers/public; a draft is fine but a human signs off before external exposure |
| **Never auto-generate** | App Store positioning copy, kinnokilabs.com marketing, devlog narrative, and the "shipped vs coming" honesty distinction itself | This is Echo's honesty-ledger DNA (e.g. the 2026-06-20 correction removing a false "no subscription" claim) |

**Governing rule:** anything that reaches the public App Store or a marketing site → *draft-then-human-ratify*. Anything internal/structural → *auto-sync with validation*.

---

## 2. Program shape

The maintainer chose **"Everything, phased"** — four independent sub-projects, each with its own spec → plan → build cycle.

### The shared spine: a "change extractor"

Three of the four workstreams need the same primitive: *"what changed between git ref X and ref Y, as a categorized, user-facing list?"* Building it once, as a pure tested unit with a clear interface `(refX, refY) → CategorizedChanges`, avoids three bespoke git-parsers.

Consumers:
- **A** — `merge-base(weekly, HEAD)..HEAD` → drafts `what_to_test.txt`
- **B** — `last-release-tag..new-tag` → drafts `release_notes.txt` + a CHANGELOG section
- **C** — PR `base…head` → "these services/columns changed; here are the docs that mention them and now look stale"

The spine leans on **Conventional Commits**, which CLAUDE.md already mandates.

### Phase sequence

```
Phase 1 ── Change-extractor spine + Workstream A   (nightly what_to_test draft)   ← this spec
Phase 2 ── Workstream B    (release-tag → release_notes.txt + metadata validators)
Phase 3 ── Workstream C    (PR-time docs-staleness gate)
Phase 4 ── Workstream D    (3-site content unification + HTML→MD migration)
```

Each phase is independently shippable. Phase 1 is first because it is the felt daily pain **and** it stands up the spine, making 2 and 3 cheap. Phase 4 (website unification) is largest and most independent, so it goes last.

**Out of scope for write-automation, all phases:** the **kickstart** MCP. It is not wired into the repo, and its CMS/blog is a confirmed phantom (not a publishing surface). It remains a read-only analytics/ASO advisor used out-of-band.

---

## 3. Phase 1 — Nightly "What to Test" automation

### 3.1 Decisions (locked during brainstorming)

| Decision | Choice | Rationale |
|---|---|---|
| **Human-in-the-loop** | *Fresh internal, curated external* | Nightly → internal testers (instant, no review) regenerates fresh and ships unreviewed. Weekly → external testers + Apple Beta App Review uses the human-curated committed file. Matches the stakes asymmetry. |
| **Change window** | *Cumulative since last weekly* | `merge-base(origin/weekly, HEAD)..HEAD` — stateless (no CI tags/bookkeeping). One narrative refined as it climbs the ladder. |
| **Filter** | `feat` + `fix` + `perf`, plus trailers | `Tester-note:` forces a custom bullet; `skip-changelog` hides a commit. Best signal-to-noise with a manual override. |
| **Generation method** | Deterministic transform of commit subjects — **no LLM** on the unreviewed nightly path | An unreviewed, hallucinated/overclaimed bullet reaching testers is the exact honesty-ledger failure mode being avoided. |
| **CI hook location** | Fastfile `beta` lane, **not** `release-trains.yml` | The lane lives on the train branch (reached via the normal `→ nightly` PR route); `release-trains.yml` lives on `main`. Hooking the lane keeps all of Phase 1 off `main`. |

### 3.2 Components (each independently testable)

| Unit | Path | Responsibility | Purity |
|---|---|---|---|
| `changes.py` | `Scripts/doc_automation/changes.py` | Parse commit records → filter by type (`feat`/`fix`/`perf`) + trailers → categorize. **Reusable spine for Phases 2–3.** | Pure |
| `render_testflight.py` | `Scripts/doc_automation/render_testflight.py` | `CategorizedChanges` + template → "What to Test" string; enforces the 4000-char cap with graceful "…and N more changes" truncation. | Pure |
| `whats_new.py` | `Scripts/doc_automation/whats_new.py` | CLI: run `git log`, wire the two pure modules, apply fallback, write the output file. | I/O shell |
| `what_to_test.template.txt` | `fastlane/testflight/what_to_test.template.txt` | Human-owned frame with a `{{CHANGES}}` placeholder. Human owns the voice; machine owns the list. | Data |
| Tests | `Scripts/doc_automation/tests/` | pytest unit tests for the two pure modules; a temp-repo integration test for the git plumbing. | — |

**Placement rationale:** `Scripts/` is the established repo-automation home (alongside `generate_architecture.sh`). Python over shell because the logic needs real unit tests. `Tools/` stays reserved for the transcription pipeline per CLAUDE.md.

### 3.3 Data flow (nightly)

1. `release-trains.yml` (on `main`, cron) checks out the `nightly` branch and runs `fastlane beta channel:nightly`.
2. The `beta` lane already computes `channel` at `fastlane/Fastfile:77`. **New step**, inserted after the channel-routing block (≈ after `:83`) and before the `File.read("testflight/what_to_test.txt")` at `fastlane/Fastfile:143`, guarded by `channel == "nightly"`:
   ```ruby
   if channel == "nightly"
     sh("cd .. && git fetch --no-tags origin weekly && " \
        "python3 Scripts/doc_automation/whats_new.py " \
        "--base $(git merge-base origin/weekly HEAD) --head HEAD " \
        "--template fastlane/testflight/what_to_test.template.txt " \
        "--out fastlane/testflight/what_to_test.txt")
   end
   ```
   (Exact invocation finalized in the implementation plan; the lane runs from `fastlane/`, so paths are repo-root-relative via `cd ..`.)
3. `whats_new.py`: `git log` the range → `changes.py` filters/categorizes → `render_testflight.py` fills the template and caps length → overwrites `fastlane/testflight/what_to_test.txt` **in the working tree only (never committed)**.
4. The lane reads the file exactly as it does today (`fastlane/Fastfile:143`) → uploads to the internal "Nightly" group.
5. **Weekly channel:** the guard is false → the file is the committed, curated copy → ships to external testers + Beta App Review.
6. **Promotion time:** the maintainer runs `make whats-new` locally to regenerate the cumulative list, then pastes/commits the curated result into the `nightly → weekly` promotion PR as `what_to_test.txt`. The generated draft seeds the human edit exactly when that PR is already being opened.

### 3.4 Error handling — the unreviewed path must never break a build or ship garbage

- **Generator throws / git error / empty output:** fall back to the committed `what_to_test.txt` (always a valid curated file). Emit a CI warning; do **not** fail the build.
- **Empty delta** (e.g. immediately after a promotion, `merge-base..HEAD` is empty): fall back to the committed file (or an evergreen "no user-facing changes since the last weekly" frame line). Honest and non-breaking.
- **Output > 4000 chars:** truncate gracefully with a trailing "…and N more changes" line.
- **Shallow-clone gotcha:** the lane must `git fetch origin weekly` (and ensure enough history) before `merge-base`, or it fails on CI's shallow checkout. Flagged for the plan.

### 3.5 Filtering & cleaning rules (for the pure core)

- **Include** commit subjects whose Conventional-Commit type is `feat`, `fix`, or `perf`.
- **Exclude** `chore`, `ci`, `docs`, `refactor`, `test`, `build`, `style`, and any non-Conventional subject (e.g. raw merge-commit subjects) — unless overridden by a trailer.
- **Trailers** (git footer lines on a commit):
  - `Tester-note: <text>` → emit `<text>` verbatim as a bullet, regardless of type.
  - `skip-changelog` (or `Skip-Changelog: true`) → drop the commit even if it is `feat`/`fix`/`perf`.
- **Subject cleaning:** strip the `type(scope):` prefix, capitalize the first letter, drop a trailing period. Example: `feat(reader): pinch-to-zoom` → `Pinch-to-zoom in the reader` (scope folded into a natural phrase where trivial; otherwise the cleaned summary alone).
- **Grouping:** bullets grouped under fixed headings — "New" (`feat`), "Fixed" (`fix`), "Improved" (`perf`) — omitting any empty group.

### 3.6 Testing (TDD)

Write tests first for the two pure modules:
- Type filtering: `feat`/`fix`/`perf` included; `chore`/`ci`/`docs`/`refactor`/`test`/`build`/`style` excluded.
- Subject cleaning: prefix strip, capitalization, period strip.
- Trailers: `Tester-note:` forces a bullet; `skip-changelog` hides one.
- Grouping: empty groups omitted; ordering New → Fixed → Improved.
- Char cap: output capped at 4000 with a truncation summary line.
- Empty-delta and fallback behavior.

Git plumbing (`whats_new.py`) gets one integration test against a temporary git repo (or a fixture of `git log` output), keeping I/O at the edge. Mirrors the project's `DatabaseService(inMemory:)` ethos: pure logic isolated, I/O at the boundary.

### 3.7 Local affordance

Add a `make whats-new` target (mirrors `make architecture`) that runs `whats_new.py` against the current branch and prints the result to stdout for a dry run, and serves as the promotion-time generator in step 6.

### 3.8 Deployment sequencing (ladder discipline)

All of Phase 1 lands via the **normal `→ nightly` PR route** — no `main`-targeting change required:
1. `Scripts/doc_automation/*`, tests, the template file, and the `make whats-new` target land on `nightly`. Inert until called.
2. The Fastfile `beta`-lane edit lands on `nightly` in the same PR. The guard (`channel == "nightly"`) means it activates on the next nightly cron run and stays inert when promoted to `weekly`.
3. No edit to `release-trains.yml` (which lives on `main`).

---

## 4. Documentation impact (doc-sync mandate)

Phase 1 adds release-engineering machinery, so the implementation must close with:
- **ARCHITECTURE.md** — a note in the Release Engineering / Promotion Ladder section describing the nightly `what_to_test.txt` auto-draft and the Fastfile hook.
- **README.md** — a brief mention if release tooling is surfaced there.
- **CHANGELOG.md** — an entry under the current beta.

---

## 5. Non-goals (Phase 1)

- No App Store metadata changes (`release_notes.txt`, `description.txt`) — that is Phase 2, release-gated.
- No PR-time docs-staleness gate — Phase 3.
- No website changes — Phase 4.
- No LLM in the generation path.
- No edit to `release-trains.yml` or any `main`-targeting change.
- No changes to `beta_app_description.txt` (evergreen, stays manual).
- No kickstart integration.
